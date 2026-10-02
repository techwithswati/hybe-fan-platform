"""
HYBE Fan Platform - Merch Service
Simulates a flash merchandise drop (BTS Butter hoodies, NewJeans photobooks, etc.)
Handles inventory management, cart locking, and puchase confirmation.
"""

import os
import time
import random
import logging
from datetime import datetime, timedelta
from flask import Flask, jsonify, request
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text
import redis

# ---- Config ------------------------------------------------------------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger("merch-service")

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "3306")
DB_USER = os.environ.get("DB_USER", "hybeadmin")
DB_PASS = os.environ.get("DB_PASS", "changeme")
DB_NAME = os.environ.get("DB_NAME", "hybe_merch")
REDIS_HOST = os.environ.get("REDIS_HOST", "redis-service")
POD_NAME = os.environ.get("POD_NAME", "merch-pod-local")
CART_TTL_SECONDS = int(os.environ.get("CART_TTL_SECONDS", "300"))               # 5 min cart lock

app.config["SQLALCHEMY_DATABASE_URI"] = (
    f"mysql+pymysql://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
)
app.config["SQLALCHEMY_POOL_SIZE"] = 10
app.config["SQLALCHEMY_MAX_OVERFLOW"] = 20
app.config["SQLALCHEMY_POOL_RECYCLE"] = 1800

db = SQLAlchemy(app)
rdb = redis.Redis(host=REDIS_HOST, port=6379, decode_responses=True)

# ---- Module -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

class MerchItem(db.Model):
    __tablename__ = "merch_items"
    id = db.Column(db.Integer, primary_key=True)
    sku = db.Column(db.String(32), unique=True, nullable=False)
    name = db.Column(db.String(128), nullable=False)
    artist = db.Column(db.String(64), nullable=False)
    price_krw = db.Column(db.Integer, nullable=False)       # Price in Korean Won
    stock_quantity = db.Column(db.Integer, default=0)
    is_limited = db.Column(db.Boolean, default=True)


class Order(db.Model):
    __tablename__ = "orders"
    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    fan_id = db.Column(db.String(64), nullable=False, index=True)
    sku = db.Column(db.String(32), nullable=False, index=True)
    quantity = db.Column(db.Integer, nullable=False, default=1)
    total_krw = db.Column(db.Integer, nullable=False)
    status = db.Column(db.String(20), default="confirmed")
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    pod_served_by = db.Column(db.String(64))


# --- Startup Seed Data ------------------------------------------------------------------------------------------------------------------------------------------------------------------

MERCH_CATALOG = [
    {"sku": "BTS-HOODIE-BUTTER", "name": "BTS Butter Hoodie (Limited)", "artist": "BTS", "price_krw": 89000, "stock": 3000},
    {"sku": "SVT-CAP-2025", "name": "SEVENTEEN World Tour Cap", "artist": "SEVENTEEN", "price_krw": 45000, "stock":5000},
    {"sku": "NJ-PHOTOBOOK-OMG", "name": "NewJeans OMG Photobook", "artist": "NewJeans", "price_krw": 65000, "stock":2000},
    {"sku": "LE-POSTER-SIGNED", "name": "LE SSERAFIM Signed Poster", "artist": "LE SSERAFIM", "price_krw": 120000, "stock": 500},
    {"sku": "TXT-LIGHTSTICK-V2", "name": "TXT Official Lightstick V2", "artist": "TXT", "price_krw": 58000, "stock": 4000},
]


def init_db():
    with app.app_context():
        db.create_all()
        # Seed inventory in Redis for atomic stock management
        for item in MERCH_CATALOG:
            stock_key = f"merch:{item['sku']}:stock"
            if not rdb.exists(stock_key):
                rdb.set(stock_key, item["stock"])
                logger.info(f"Seeded {item['stock']} units for SKU {item['sku']}")
                
                
# ----- Health Checks ---------------------------------------------------------------------------------------------------------------------------------------------------------------------

@app.route("/health/live", methods=["GET"])
def liveness():
    return jsonify({"status": "alive", "service": "merch", "pod": POD_NAME}), 200


@app.route("/health/ready", methods=["GET"])
def readiness():
    try:
        db.session.execute(text("SELECT 1"))
        rdb.ping()
        return jsonify({"status": "ready", "pod": POD_NAME}), 200
    except Exception as e:
        logger.error(f"Readiness failed: {e}")
        return jsonify({"status": "not ready", "error": str(e)}), 503
    
    
# ----- API Endpoints -------------------------------------------------------------------------------------------------------------------------------------------------------------------

@app.route("/api/v1/merch/catalog", methods=["GET"])
def get_catalog():
    """
    Returns all merch items with live stock levels from Redis.
    Frontend polls this every 5s during a drop.
    """
    catalog = []
    for item in MERCH_CATALOG:
        stock_key = f"merch:{item['sku']}:stock"
        remaining = int(rdb.get(stock_key) or 0)
        catalog.append({
            "sku": item["sku"],
            "name": item["name"],
            "artist": item["artist"],
            "price_krw": item["price_krw"],
            "price_usd": round(item["price_krw"] / 1350, 2),
            "stock_remaining": remaining,
            "status": "available" if remaining > 0 else "sold out",
            "is_limited": True,
        })
    
    return jsonify({
        "catalog": catalog,
        "served_by": POD_NAME,
        "timestamp": datetime.utcnow().isoformat(),
    }), 200


@app.route("/api/v1/merch/cart/lock", methods=["POST"])
def lock_cart():
    """
    Reserves stock for 5 minutes while fan checks out.
    Uses Redis SETNX for atomic lock - prevents double booking.
    """
    data = request.get_json()
    fan_id = data.get("fan_id")
    sku = data.get("sku")
    quantity = int(data.get("quantity", 1))
    
    if not all([fan_id, sku]):
        return jsonify({"error": "fan_id and sku are required"}), 400

    # One cart lock per fan per item
    lock_key = f"cart:lock:{fan_id}:{sku}"
    stock_key = f"merch:{sku}:stock"
    
    # Check if fan already has a cart lock
    if rdb.exists(lock_key):
        ttl = rdb.ttl(lock_key)
        return jsonify({
            "success": False,
            "mesage": f"You already have this item reserved. Complete checkout in {ttl}s",
        }), 409
        
    # Atomic: decrement stock and set cart lock
    remaining = rdb.decrby(stock_key, quantity)
    if remaining < 0:
        rdb.incrby(stock_key, quantity)             # Rollback
        return jsonify ({"success": False, "message": "Sold out 😭"}), 409
    
    # Set cart lock with TTL (auto-releases if checkout not completed)
    cart_data = f"{fan_id}:{sku}:{quantity}"
    rdb.setex(lock_key, CART_TTL_SECONDS, cart_data)
    
    logger.info(
        f"CART LOCKED - fan={fan_id} sku ={sku} qty={quantity} "
        f"remaining={remaining} ttl={CART_TTL_SECONDS}s"
    )
    
    return jsonify({
        "success": True,
        "fan_id": fan_id,
        "sku": sku,
        "quantity": quantity,
        "cart_expires_in": CART_TTL_SECONDS,
        "stock_remaining": remaining,
        "message": "Item reserved! Complete checkout in 5 minutes ⏱️",
    }), 200
    

@app.route("/api/v1/merch/purchase", methods=["POST"])
def purchase():
    """
    Confirms purchase after payment. Validates cart lock exists.
    Writes final order to RDS MySQL.
    """
    data = request.get_json()
    fan_id = data.get("fan_id")
    sku = data.get("sku")
    quantity = int(data.get("quantity", 1))
    
    lock_key = f"cart:lock:{fan_id}:{sku}"
    
    # Validate cart lock still exists
    if not rdb.exists(lock_key):
        return jsonify({
            "success": False,
            "message": "Cart expired. Stock has been released.",
        }), 410
        
    # Simulate payment processing
    time.sleep(random.uniform(0.02, 0.08))
    
    # Find price
    item_data = next((i for i in MERCH_CATALOG if i["sku"] == sku), None)
    if not item_data:
        return jsonify({"error": "Invalid SKU"}), 404
    
    total_krw = item_data["price_krw"] * quantity
    
    # Persist order to RDS
    order = Order(
        fan_id=fan_id,
        sku=sku,
        quantity=quantity,
        total_krw=total_krw,
        status="confirmed",
        pod_served_by=POD_NAME,
    )
    db.session.add(order)
    db.session.commit()
    
    # Release cart lock (order confirmed)
    rdb.delete(lock_key)
    
    logger.info(
        f"ORDER CONFIRMED - fan={fan_id} sku={sku} qty={quantity} "
        f"total=₩{total_krw:,} order_id={order.id} pod={POD_NAME}"
    )
    
    return jsonify({
        "success": True,
        "order_id": order.id,
        "fan_id": fan_id,
        "sku": sku,
        "item_name": item_data["name"],
        "quantity": quantity,
        "total_krw": total_krw,
        "total_usd": round(total_krw / 1350, 2),
        "status": "confirmed",
        "estimated_shipping": (datetime.utcnow() + timedelta(days=14)).strftime("%Y-%m-%d"),
        "served_by": POD_NAME,
        "message": "Order confirmed! Ships from Seoul in 14 days 📦✈️",
    }), 201
    
    
@app.route("/api/v1/merch/inventory", methods=["GET"])
def inventory_summary():
    """Summary endpoint for Grafana dashboard."""
    summary = []
    for item in MERCH_CATALOG:
        stock_key = f"merch:{item['sku']}:stock"
        remaining = int(rdb.get(stock_key) or 0)
        sold = max(0, item["stock"] - remaining)
        summary.append({
            "sku": item["sku"],
            "artist": item["artist"],
            "total": item["stock"],
            "sold": sold,
            "remaining": remaining,
            "sell_through_pct": round((sold / item["stock"]) * 100, 1),
        })
    
    return jsonify({"inventory": summary, "pod": POD_NAME}), 200


# ---- Entrypoint ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=8081, threaded=True)

"""
HYBE Fan Platform - Ticket Service
Simulates a high-concurrency ticket release queue (BTS World Tour, etc.)
Uses Redis for distributed queue + RDS for persistent booking records.
"""

import os
import time
import random
import logging
from datetime import datetime
from flask import Flask, jsonify, request
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text
import redis

# ---- Config ------------------------------------------------------------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
) 
logger = logging.getLogger("ticket-service")

app = Flask(__name__)

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "3306")
DB_USER = os.environ.get("DB_USER", "hybeadmin")
DB_PASS = os.environ.get("DB_PASS", "changeme")
DB_NAME = os.environ.get("DB_NAME", "hybe_tickets")
REDIS_HOST = os.environ.get("REDIS_HOST", "redis-service")
TOTAL_TICKETS = int(os.environ.get("TOTAL_TICKETS", "5000"))
POD_NAME = os.environ.get("POD_NAME", "ticket-pod-local")

app.config["SQLALCHEMY_DATABASE_URI"] = (
    f"mysql+pymysql://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
)
app.config["SQLALCHEMY_POOL_SIZE"] = 10
app.config["SQLALCHEMY_MAX_OVERFLOW"] = 20
app.config["SQLALCHEMY_POOL_TIMEOUT"] = 30
app.config["SQLALCHEMY_POOL_RECYCLE"] =1800

db = SQLAlchemy(app)
rdb = redis.Redis(host=REDIS_HOST, port=6379, decode_responses=True)

# --- Models -------------------------------------------------------------------------------------------------------------------------------------------------------

class Booking(db.Model):
    __tablename__ = "bookings"
    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    fan_id = db.Column(db.String(64), nullable=False, index=True)
    event_id = db.Column(db.String(64), nullable=False, index=True)
    seat_zone = db.Column(db.String(10), nullable=False)
    status = db.Column(db.String(20), default="pending") # pending | confirmed | failed
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    pod_served_by = db.Column(db.String(64))    # Track which pod handled it
    
    
# ---- Startup -----------------------------------------------------------------------------------------------------------------------------------------------------

def init_db():
    with app.app_context():
        db.create_all()
        # Seed Redis ticket pool for this event
        event_key = "event:bts-world-tour-2025:tickets"
        if not rdb.exists(event_key):
            rdb.set(event_key, TOTAL_TICKETS)
            logger.info(f"Initialized {TOTAL_TICKETS} tickets in Redis pool")
            
            
# ---- Health Checks ------------------------------------------------------------------------------------------------------------------------------------------------

@app.route("/health/live", methods=["GET"])
def liveness():
    """Kubernetes liveness probe."""
    return jsonify({"status": "alive", "pod": POD_NAME}), 200


@app.route("/health/ready", methods=["GET"])
def readiness():
    """Kubernetes readiiness probe - check DB + Redis."""
    try:
        db.session.execute(text("SELECT 1"))
        rdb.ping()
        return jsonify({"status": "ready", "pod": POD_NAME}), 200
    except Exception as e:
        logger.error(f"Readiness check failed: {e}")
        return jsonify({"status": "not ready", "error": str(e)}), 503
    
    
# ------ API Endpoints --------------------------------------------------------------------------------------------------------------------------------------------------

@app.route("/api/v1/tickets/availability", methods=["GET"])
def check_availability():
    """
    Returns remaining tickets for an event.
    Called by frontend before the drop to show countdown.
    """
    event_id = request.args.get("event_id", "bts-world-tour-2025")
    event_key = f"event:{event_id}:tickets"
    remaining = rdb.get(event_key) or 0
    
    return jsonify({
        "event_id": event_id,
        "tickets_remaining": int(remaining),
        "status": "on_sale" if int(remaining) > 0 else "sold_out",
        "served_by_pod": POD_NAME,
        "timestamp": datetime.utcnow().isoformat(),
    }), 200
    
    
@app.route("/api/v1/tickets/purchase", methods=["POST"])
def purchase_ticket():
    """
    Atomic ticket purchase using Redis DECR.
    Simulates 50k fans simultaneously hitting this endpooint.
    """
    data = request.get_json()
    fan_id = data.get("fan_id")
    event_id = data.get("event_id", "bts-world-tour-2025")
    seat_zone = data.get("seat_zone", random.choice(["VIP", "A", "B", "C"]))
    
    if not fan_id:
        return jsonify({"error": "fan_id is required"}), 400
    
    event_key = f"event:{event_id}:tickets"
    
    # ---- Atomic Redis decrement (prevents overselling) -----------------------------------------------------------------------------------------------------
    remaining = rdb.decr(event_key)
    
    if remaining < 0:
        # Restore counter - someone else got this ticket
        rdb.incr(event_key)
        logger.warning(f"SOLD OUT - fan={fan_id} was too late")
        return jsonify({
            "success": False,
            "message": "Sorry, tickets are sold out. You were so close! 😢",
            "event_id": event_id,
        }), 409
        
    # --- Simulate processing time (DB write, payment gateway call) ---------------------------------------------------------------------------------------------
    time.sleep(random.uniform(0.01, 0.05))
    
    # --- Persist booking to RDS --------------------------------------------------------------------------------------------------------------------------------
    booking = Booking(
        fan_id=fan_id,
        event_id=event_id,
        seat_zone=seat_zone,
        status="confirmed",
        pod_served_by=POD_NAME,
    )
    db.session.add(booking)
    db.session.commit()
    
    logger.info(
        f"TICKET SOLD - fan={fan_id} event={event_id} "
        f"zone={seat_zone} remanining={remaining} pod={POD_NAME}"
    )
    
    return jsonify({
        "success": True,
        "booking_id": booking.id,
        "fan_id": fan_id,
        "event_id": event_id,
        "seat_zone": seat_zone,
        "status": "confirmed",
        "tickets_remaining": remaining,
        "served_by_pod": POD_NAME,
        "message": f"Congratulations! Your {seat_zone} ticket is confirmed 🎉",
    }), 201
    
    
@app.route("/api/v1/tickets/queue-status", methods=["GET"])
def queue_status():
    """Returns overall queue metrics - used by Grafana dashboard."""
    event_id = request.args.get("event_id", "bts-world-tour-2025")
    event_key = f"event:{event_id}:tickets"
    remaining = int(rdb.get(event_key) or 0)
    sold = max(0, TOTAL_TICKETS - remaining)
    
    return jsonify({
        "event_id": event_id,
        "total_tickets": TOTAL_TICKETS,
        "sold": sold,
        "remaining": remaining,
        "sell_through_pct": round((sold / TOTAL_TICKETS) * 100, 2),
        "pod": POD_NAME,
    }), 200
    
    
# ---- Entrypoint -------------------------------------------------------------------------------------------------------------------------------------------------------------------------

if __name__ == "__main__":
    print("Starting ticket service...")
    try:
        init_db()
        print("Database initialized successfully.")
    except Exception as e:
        print(f"ERROR in init_db(): {e}")
        import traceback
        traceback.print_exc()
        # Optionally exit here or continue
        # sys.exit(1)
    print("Starting Flask server...")
    app.run(host="0.0.0.0", port=8080, threaded=True)
    
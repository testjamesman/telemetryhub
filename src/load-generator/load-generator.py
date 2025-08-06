# src/load-generator/load_generator.py
import os
import time
import boto3
import random
from flask import Flask, render_template, request, jsonify
from threading import Thread, Event
import logging
import uuid

# --- Logging Setup ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# --- Flask App Setup ---
app = Flask(__name__)

# --- AWS Config ---
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL")
sqs = boto3.client("sqs", region_name=os.environ.get("AWS_REGION", "us-east-1"))

# --- Load Generation State ---
class LoadGenerator:
    def __init__(self):
        self.thread = None
        self.stop_event = Event()
        self.requests_per_minute = 60
        self.error_rate_percent = 0
        self.is_running = False

    def start(self, rpm, error_rate):
        if self.is_running:
            logging.warning("Load generator is already running.")
            return

        self.requests_per_minute = rpm
        self.error_rate_percent = error_rate
        self.stop_event.clear()
        self.thread = Thread(target=self.run)
        self.thread.daemon = True
        self.thread.start()
        self.is_running = True
        logging.info(f"Load generator started with {rpm} RPM and {error_rate}% error rate.")

    def stop(self):
        if not self.is_running:
            logging.warning("Load generator is not running.")
            return

        self.stop_event.set()
        self.thread.join()
        self.is_running = False
        logging.info("Load generator stopped.")

    def run(self):
        while not self.stop_event.is_set():
            # Calculate sleep time to match the desired RPM
            sleep_interval = 60.0 / self.requests_per_minute
            
            try:
                # Introduce errors based on the specified rate
                if random.randint(1, 100) <= self.error_rate_percent:
                    logging.error("Simulating a message send failure.")
                else:
                    message_id = str(uuid.uuid4())
                    message_content = f"LoadGen message at {time.time()}"
                    sqs.send_message(
                        QueueUrl=SQS_QUEUE_URL,
                        MessageBody=message_content,
                        MessageGroupId="telemetry-hub-loadgen",
                        MessageDeduplicationId=message_id
                    )
                    logging.info(f"Sent message {message_id} to SQS.")
            except Exception as e:
                logging.error(f"Failed to send message to SQS: {e}")

            time.sleep(sleep_interval)

# Global instance of the load generator
load_gen = LoadGenerator()

# --- API Endpoints ---
@app.route('/')
def index():
    return render_template('index.html')

@app.route('/start', methods=['POST'])
def start_load():
    data = request.json
    rpm = int(data.get('rpm', 60))
    error_rate = int(data.get('error_rate', 0))
    load_gen.start(rpm, error_rate)
    return jsonify({"status": "started"})

@app.route('/stop', methods=['POST'])
def stop_load():
    load_gen.stop()
    return jsonify({"status": "stopped"})

@app.route('/status')
def status():
    return jsonify({
        "running": load_gen.is_running,
        "rpm": load_gen.requests_per_minute,
        "error_rate": load_gen.error_rate_percent
    })

@app.route('/invoke-once', methods=['POST'])
def invoke_once():
    try:
        message_id = str(uuid.uuid4())
        message_content = f"Single invocation at {time.time()}"
        sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=message_content,
            MessageGroupId="telemetry-hub-single",
            MessageDeduplicationId=message_id
        )
        logging.info(f"Sent single message {message_id} to SQS.")
        return jsonify({"status": "success", "message_id": message_id})
    except Exception as e:
        logging.error(f"Failed to send single message: {e}")
        return jsonify({"status": "error", "message": str(e)}), 500

if __name__ == "__main__":
    if not SQS_QUEUE_URL:
        logging.error("FATAL: SQS_QUEUE_URL environment variable is not set.")
    else:
        app.run(host='0.0.0.0', port=8080)


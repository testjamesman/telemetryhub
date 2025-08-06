# processor.py
import os
import time
import boto3
import psycopg2
from opentelemetry import trace
from flask import Flask
from prometheus_flask_exporter import PrometheusMetrics
from threading import Thread
import logging

# --- Logging Setup ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# --- Flask & Prometheus Setup ---
# This creates a Flask web server to expose the /metrics endpoint
app = Flask(__name__)
# This automatically adds Prometheus metrics for HTTP requests to the /metrics endpoint
# We disable the default Python/process metrics as the agent should collect them.
metrics = PrometheusMetrics(app, export_defaults=False)

# --- OpenTelemetry Setup ---
# The agent's OTel distribution is expected to automatically configure the tracer
# and export the spans created here.
tracer = trace.get_tracer(__name__)

# --- AWS & DB Config ---
# These environment variables will be passed in from the Kubernetes deployment manifest.
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL")
DB_HOST = os.environ.get("DB_HOST")
DB_NAME = os.environ.get("DB_NAME")
DB_USER = os.environ.get("DB_USER")
DB_PASS = os.environ.get("DB_PASS")
# -----------------------

# Initialize the SQS client
sqs = boto3.client("sqs", region_name=os.environ.get("AWS_REGION", "us-east-1"))

def get_db_connection():
    """Establishes a new connection to the PostgreSQL database."""
    conn = psycopg2.connect(
        host=DB_HOST,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )
    return conn

def process_messages():
    """
    Receives a batch of messages from SQS, processes them, writes to the database,
    and deletes them from the queue.
    """
    # Start a new span for the batch processing operation.
    with tracer.start_as_current_span("process_sqs_batch") as span:
        try:
            logging.info("Polling SQS for new messages...")
            response = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=5,
                WaitTimeSeconds=10 # Use long polling
            )
        except Exception as e:
            logging.error(f"Error receiving from SQS: {e}")
            span.set_attribute("error", True)
            span.record_exception(e)
            return

        messages = response.get("Messages", [])
        span.set_attribute("messages.count", len(messages))

        if not messages:
            logging.info("No messages received in this poll.")
            return

        logging.info(f"Received {len(messages)} messages to process.")
        conn = get_db_connection()
        for msg in messages:
            # Create a child span for each individual message.
            with tracer.start_as_current_span("process_single_message") as msg_span:
                message_id = msg['MessageId']
                content = msg['Body']
                msg_span.set_attribute("message.id", message_id)
                logging.info(f"Processing message: {message_id}")

                try:
                    # Write to DB
                    cur = conn.cursor()
                    cur.execute(
                        "INSERT INTO processed_messages (message_id, content) VALUES (%s, %s)",
                        (message_id, content)
                    )
                    conn.commit()
                    cur.close()

                    # Delete from SQS
                    sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=msg['ReceiptHandle'])
                    logging.info(f"Successfully processed and deleted message {message_id}")

                except Exception as e:
                    logging.error(f"Error processing message {message_id}: {e}")
                    msg_span.set_attribute("error", True)
                    msg_span.record_exception(e)

        conn.close()

def main_loop():
    """The main application loop that continuously processes messages."""
    logging.info("Starting data processor loop...")
    while True:
        process_messages()
        time.sleep(5)

if __name__ == "__main__":
    # We run the message processing loop in a separate thread
    # so it doesn't block the Flask web server from running.
    processing_thread = Thread(target=main_loop)
    processing_thread.daemon = True
    processing_thread.start()

    # Start the Flask web server to expose the /metrics endpoint.
    app.run(host='0.0.0.0', port=8000)

# processor.py
import os
import time
import boto3
import psycopg2
from psycopg2 import sql
from opentelemetry import trace
from flask import Flask
from prometheus_flask_exporter import PrometheusMetrics
from threading import Thread
import logging

# --- Logging Setup ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# --- Flask & Prometheus Setup ---
app = Flask(__name__)
metrics = PrometheusMetrics(app, export_defaults=False)

# --- OpenTelemetry Setup ---
tracer = trace.get_tracer(__name__)

# --- AWS & DB Config ---
SQS_QUEUE_URL = os.environ.get("SQS_QUEUE_URL")
DB_HOST = os.environ.get("DB_HOST")
DB_NAME = os.environ.get("DB_NAME", "telemetryhubdb")
DB_USER = os.environ.get("DB_USER", "dbadmin")
DB_PASS = os.environ.get("DB_PASSWORD")
# -----------------------

sqs = boto3.client("sqs", region_name=os.environ.get("AWS_REGION", "us-east-1"))

def get_db_connection(db_name_override=None):
    """Establishes a new connection to the PostgreSQL database using SSL."""
    if not DB_PASS:
        logging.error("FATAL: DB_PASSWORD environment variable is not set.")
        return None
    
    db_to_connect = db_name_override if db_name_override else DB_NAME
    
    conn = None
    try:
        # Use sslmode='require' for secure connections to RDS
        conn_string = f"host={DB_HOST} dbname={db_to_connect} user={DB_USER} password={DB_PASS} sslmode='require'"
        conn = psycopg2.connect(conn_string)
        return conn
    except Exception as e:
        logging.error(f"Failed to connect to the database '{db_to_connect}': {e}")
        return None

def process_messages():
    """
    Receives a batch of messages from SQS, processes them, writes to the database,
    and deletes them from the queue.
    """
    try:
        with tracer.start_as_current_span("process_sqs_batch") as span:
            logging.info("Polling SQS for new messages...")
            response = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=5,
                WaitTimeSeconds=10
            )
            messages = response.get("Messages", [])
            span.set_attribute("messages.count", len(messages))

            if not messages:
                logging.info("No messages received in this poll.")
                return

            logging.info(f"Received {len(messages)} messages to process.")
            conn = get_db_connection()
            if conn is None:
                logging.error("Cannot process messages, no database connection.")
                # Wait before retrying
                time.sleep(10)
                return

            for msg in messages:
                with tracer.start_as_current_span("process_single_message") as msg_span:
                    message_id = msg['MessageId']
                    content = msg['Body']
                    msg_span.set_attribute("message.id", message_id)
                    logging.info(f"Processing message: {message_id}")

                    try:
                        cur = conn.cursor()
                        cur.execute(
                            "INSERT INTO processed_messages (message_id, content) VALUES (%s, %s)",
                            (message_id, content)
                        )
                        conn.commit()
                        cur.close()
                        sqs.delete_message(QueueUrl=SQS_QUEUE_URL, ReceiptHandle=msg['ReceiptHandle'])
                        logging.info(f"Successfully processed and deleted message {message_id}")
                    except Exception as e:
                        logging.error(f"Error processing message {message_id}: {e}", exc_info=True)
                        msg_span.set_attribute("error", True)
                        msg_span.record_exception(e)
            conn.close()
    except Exception as e:
        logging.error(f"An unhandled error occurred in process_messages loop: {e}", exc_info=True)


def main_loop():
    """The main application loop that continuously processes messages."""
    logging.info("Starting data processor loop...")
    while True:
        process_messages()
        time.sleep(5)

if __name__ == "__main__":
    # --- Initial Setup ---
    # This startup sequence is now robust against race conditions with RDS.
    logging.info("--- Python Processor Starting Up ---")
    
    # --- Start Application Threads ---
    logging.info("Starting background message processing thread...")
    processing_thread = Thread(target=main_loop)
    processing_thread.daemon = True
    processing_thread.start()

    # --- Run Flask App ---
    logging.info("Starting Flask server for metrics on port 8000...")
    app.run(host='0.0.0.0', port=8000)

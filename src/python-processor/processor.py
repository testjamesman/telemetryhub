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
DB_NAME = os.environ.get("DB_NAME", "telemetryhubdb") # Default to the db we are configuring
DB_USER = os.environ.get("DB_USER", "dbadmin")       # Default to the user we are configuring
DB_PASS = os.environ.get("DB_PASS")
# -----------------------

sqs = boto3.client("sqs", region_name=os.environ.get("AWS_REGION", "us-east-1"))

def get_db_connection(db_name='postgres'):
    """Establishes a new connection to the PostgreSQL database."""
    # Connect to a specified database, defaulting to 'postgres' for initial setup.
    conn = psycopg2.connect(
        host=DB_HOST,
        dbname=db_name,
        user=DB_USER,
        password=DB_PASS
    )
    return conn

def configure_postgres_access():
    """
    Finds pg_hba.conf, adds a rule to allow all IP access for the user, and reloads config.
    *** WARNING: This is insecure and for demonstration purposes only. ***
    """
    conn = None
    rule = f"host\t{DB_NAME}\t{DB_USER}\t0.0.0.0/0\ttrust\n"
    logging.info("Attempting to configure PostgreSQL access...")

    try:
        conn = get_db_connection() # Connects to 'postgres' db by default
        conn.autocommit = True
        cur = conn.cursor()

        logging.info("Finding pg_hba.conf file location...")
        cur.execute("SHOW hba_file;")
        hba_file_path = cur.fetchone()[0]
        logging.info(f"pg_hba.conf found at: {hba_file_path}")

        with open(hba_file_path, 'r+') as f:
            hba_content = f.read()
            if rule not in hba_content:
                logging.warning(f"Rule not found. Appending insecure rule to {hba_file_path}")
                logging.warning(f"RULE: '{rule.strip()}' - THIS IS NOT SAFE FOR PRODUCTION!")
                f.write(f"\n# --- Added by Python Demo App ---\n")
                f.write(rule)

                logging.info("Reloading PostgreSQL configuration...")
                cur.execute("SELECT pg_reload_conf();")
                if cur.fetchone()[0]:
                    logging.info("PostgreSQL configuration reloaded successfully.")
                else:
                    logging.error("Failed to reload PostgreSQL configuration.")
            else:
                logging.info("Access rule already exists in pg_hba.conf. No changes needed.")

        cur.close()
        return True
    except Exception as e:
        logging.error(f"An error occurred during pg_hba.conf update: {e}", exc_info=True)
        return False
    finally:
        if conn:
            conn.close()


def create_db_table():
    """Creates the processed_messages table if it doesn't exist."""
    conn = None
    try:
        # Now, connect to the specific application database
        conn = get_db_connection(db_name=DB_NAME)
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS processed_messages (
                id SERIAL PRIMARY KEY,
                message_id VARCHAR(255) NOT NULL,
                content VARCHAR(255),
                processed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
            );
        """)
        conn.commit()
        cur.close()
        logging.info(f"Database table 'processed_messages' in '{DB_NAME}' is ready.")
        return True
    except Exception as e:
        logging.error(f"Error creating database table: {e}", exc_info=True)
        return False
    finally:
        if conn:
            conn.close()

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
            conn = get_db_connection(db_name=DB_NAME)
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
    # Try to configure and set up the database, but don't let failures here
    # stop the main application from starting. The processing loop will retry.
    logging.info("Performing initial database setup...")
    if configure_postgres_access():
        create_db_table()
    else:
        logging.warning("Initial PostgreSQL configuration failed. The application will continue and retry DB operations in the main loop.")

    # --- Start Application Threads ---
    logging.info("Starting background message processing thread...")
    processing_thread = Thread(target=main_loop)
    processing_thread.daemon = True
    processing_thread.start()

    # --- Run Flask App ---
    logging.info("Starting Flask server for metrics on port 8000...")
    app.run(host='0.0.0.0', port=8000)


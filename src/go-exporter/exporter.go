// src/go-exporter/exporter.go
package main

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	// PostgreSQL driver
	_ "github.com/lib/pq"
	// Prometheus client library
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	// --- CONFIGURATION ---
	// These environment variables will be set on the EC2 instance or locally.
	dbHost = os.Getenv("DB_HOST")
	dbUser = os.Getenv("DB_USER")
	dbPass = os.Getenv("DB_PASSWORD")
	dbName = os.Getenv("DB_NAME")
	// ---------------------

	// Define a Prometheus Gauge metric. A Gauge is a metric that represents
	// a single numerical value that can arbitrarily go up and down.
	processedMessagesTotal = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "processed_messages_total",
		Help: "The total number of processed messages in the database.",
	})
)

func init() {
	// Configure the logger to include the date, time, and file name.
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	// Register the metric with the Prometheus client library's default registry.
	prometheus.MustRegister(processedMessagesTotal)
}

func main() {
	// Log the configuration variables for debugging purposes.
	// IMPORTANT: Never log passwords or other secrets.
	log.Println("--- Go Exporter Starting Up ---")
	log.Printf("Reading configuration from environment variables...")
	log.Printf("DB_HOST: %s", dbHost)
	log.Printf("DB_USER: %s", dbUser)
	log.Printf("DB_NAME: %s", dbName)
	if dbPass == "" {
		log.Println("DB_PASSWORD: [Not Set]")
	} else {
		log.Println("DB_PASSWORD: [Set]")
	}
	log.Println("---------------------------------")

	// Construct the database connection string from environment variables.
	// Use sslmode=require for connecting to cloud-based databases like RDS.
	connStr := fmt.Sprintf("host=%s user=%s password=%s dbname=%s sslmode=require", dbHost, dbUser, dbPass, dbName)

	// Open a connection to the database.
	log.Println("Attempting to connect to the database...")
	db, err := sql.Open("postgres", connStr)
	if err != nil {
		log.Fatalf("FATAL: Error creating database connection pool: %v", err)
	}
	defer db.Close()

	// Ping the database to verify the connection is alive.
	err = db.Ping()
	if err != nil {
		log.Fatalf("FATAL: Could not ping the database. Please check connection details and network access. Error: %v", err)
	}
	log.Println("✅ Database connection successful.")

	// Start a background goroutine to periodically query the database.
	log.Println("Starting background routine for periodic database queries...")
	go func() {
		for {
			log.Println("Querying for total processed messages...")
			var count int
			// Query the database for the total count of messages.
			err := db.QueryRow("SELECT COUNT(*) FROM processed_messages").Scan(&count)
			if err != nil {
				log.Printf("ERROR: Database query failed: %v", err)
			} else {
				// If the query is successful, update the Prometheus gauge.
				processedMessagesTotal.Set(float64(count))
				log.Printf("-> Found %d processed messages. Metric updated.", count)
			}
			// Wait for 30 seconds before the next query.
			log.Println("Waiting for 30 seconds until next query...")
			time.Sleep(30 * time.Second)
		}
	}()

	// Expose the registered metrics on the /metrics endpoint.
	log.Println("Starting metrics server on :8080/metrics")
	http.Handle("/metrics", promhttp.Handler())
	log.Fatal(http.ListenAndServe(":8080", nil))
}

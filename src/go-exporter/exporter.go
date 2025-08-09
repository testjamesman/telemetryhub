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
	// These environment variables will be set on the EC2 instance before running.
	dbHost = os.Getenv("DB_HOST")
	dbUser = os.Getenv("DB_USER")
	dbPass = os.Getenv("DB_PASS")
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
	// Register the metric with the Prometheus client library's default registry.
	prometheus.MustRegister(processedMessagesTotal)
}

func main() {
	// Log the configuration variables for debugging purposes.
	// IMPORTANT: Never log passwords or other secrets.
	log.Printf("Initializing exporter with the following configuration:")
	log.Printf("DB_HOST: %s", dbHost)
	log.Printf("DB_USER: %s", dbUser)
	log.Printf("DB_NAME: %s", dbName)

	// Construct the database connection string from environment variables.
	connStr := fmt.Sprintf("host=%s user=%s password=%s dbname=%s sslmode=disable", dbHost, dbUser, dbPass, dbName)

	// Open a connection to the database.
	db, err := sql.Open("postgres", connStr)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	// Start a background goroutine to periodically query the database.
	go func() {
		for {
			var count int
			// Query the database for the total count of messages.
			err := db.QueryRow("SELECT COUNT(*) FROM processed_messages").Scan(&count)
			if err != nil {
				log.Printf("Error querying database: %v", err)
			} else {
				// If the query is successful, update the Prometheus gauge.
				processedMessagesTotal.Set(float64(count))
				log.Printf("Updated total processed messages count: %d", count)
			}
			// Wait for 30 seconds before the next query.
			time.Sleep(30 * time.Second)
		}
	}()

	// Expose the registered metrics on the /metrics endpoint.
	log.Println("Starting metrics exporter on :8080/metrics")
	http.Handle("/metrics", promhttp.Handler())
	log.Fatal(http.ListenAndServe(":8080", nil))
}

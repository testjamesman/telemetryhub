// src/csharp-producer/Program.cs
using System;
using System.Diagnostics;
using System.Threading.Tasks;
using Amazon.SQS;
using Amazon.SQS.Model;

public class Program
{
    // --- CONFIGURATION ---
    // This will be set via an environment variable on the EC2 instance.
    private static readonly string SqsQueueUrl = Environment.GetEnvironmentVariable("SQS_QUEUE_URL");
    // ---------------------

    private static readonly AmazonSQSClient SqsClient = new AmazonSQSClient();
    private static readonly ActivitySource MyActivitySource = new ActivitySource("DataProducer");

    public static async Task Main(string[] args)
    {
        if (string.IsNullOrEmpty(SqsQueueUrl))
        {
            Console.WriteLine("Error: SQS_QUEUE_URL environment variable is not set.");
            return;
        }

        Console.WriteLine("Starting data producer...");
        while (true)
        {
            // The vendor's auto-instrumentation should hook into this ActivitySource
            using (var activity = MyActivitySource.StartActivity("Produce new message"))
            {
                var messageContent = $"Data generated at {DateTime.UtcNow:O}";
                var messageId = Guid.NewGuid().ToString();
                activity?.SetTag("message.content", messageContent);
                activity?.SetTag("message.id", messageId);
                Console.WriteLine($"Producing message: {messageId}");

                var request = new SendMessageRequest
                {
                    QueueUrl = SqsQueueUrl,
                    MessageBody = messageContent,
                    MessageGroupId = "telemetry-hub", // Required for FIFO queues, good practice for standard
                    MessageDeduplicationId = messageId
                };
                
                try
                {
                    var response = await SqsClient.SendMessageAsync(request);
                    Console.WriteLine($"Successfully sent message {messageId} with SQS MessageId {response.MessageId}");
                    activity?.SetTag("aws.sqs.message_id", response.MessageId);
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Error sending message to SQS: {ex.Message}");
                    activity?.SetStatus(ActivityStatusCode.Error, "Failed to send to SQS");
                }
            }
            await Task.Delay(TimeSpan.FromMinutes(1));
        }
    }
}

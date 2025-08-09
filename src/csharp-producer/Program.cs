// src/csharp-producer/Program.cs
using System;
using System.Diagnostics;
using System.Threading.Tasks;
using Amazon.SQS;
using Amazon.SQS.Model;

public class Program
{
    // --- CONFIGURATION ---
    private static readonly string SqsQueueUrl = Environment.GetEnvironmentVariable("SQS_QUEUE_URL");
    // ---------------------

    private static readonly AmazonSQSClient SqsClient = new AmazonSQSClient();
    private static readonly ActivitySource MyActivitySource = new ActivitySource("DataProducer");

    public static async Task Main(string[] args)
    {
        Console.WriteLine($"{DateTime.UtcNow:o} --- C# SQS Producer Starting Up ---");
        
        if (string.IsNullOrEmpty(SqsQueueUrl))
        {
            Console.WriteLine($"{DateTime.UtcNow:o} FATAL: SQS_QUEUE_URL environment variable is not set. Exiting.");
            return;
        }
        Console.WriteLine($"{DateTime.UtcNow:o} SQS_QUEUE_URL: {SqsQueueUrl}");
        Console.WriteLine("---------------------------------------");


        Console.WriteLine($"{DateTime.UtcNow:o} Starting data producer loop...");
        while (true)
        {
            using (var activity = MyActivitySource.StartActivity("Produce new message"))
            {
                var messageContent = $"Data generated at {DateTime.UtcNow:o}";
                var messageId = Guid.NewGuid().ToString();
                activity?.SetTag("message.content", messageContent);
                activity?.SetTag("message.id", messageId);
                
                Console.WriteLine($"{DateTime.UtcNow:o} Preparing to send message: {messageId}");

                var request = new SendMessageRequest
                {
                    QueueUrl = SqsQueueUrl,
                    MessageBody = messageContent
                };
                
                try
                {
                    var response = await SqsClient.SendMessageAsync(request);
                    Console.WriteLine($"{DateTime.UtcNow:o} -> Successfully sent message. SQS MessageId: {response.MessageId}");
                    activity?.SetTag("aws.sqs.message_id", response.MessageId);
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"{DateTime.UtcNow:o} ERROR: Failed to send message to SQS: {ex.Message}");
                    activity?.SetStatus(ActivityStatusCode.Error, "Failed to send to SQS");
                }
            }
            Console.WriteLine($"{DateTime.UtcNow:o} Waiting for 1 minute before next message...");
            await Task.Delay(TimeSpan.FromMinutes(1));
        }
    }
}

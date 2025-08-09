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
        if (string.IsNullOrEmpty(SqsQueueUrl))
        {
            Console.WriteLine($"{DateTime.UtcNow:o} Error: SQS_QUEUE_URL environment variable is not set.");
            return;
        }

        Console.WriteLine($"{DateTime.UtcNow:o} Starting data producer...");
        while (true)
        {
            using (var activity = MyActivitySource.StartActivity("Produce new message"))
            {
                var messageContent = $"Data generated at {DateTime.UtcNow:o}";
                var messageId = Guid.NewGuid().ToString();
                activity?.SetTag("message.content", messageContent);
                activity?.SetTag("message.id", messageId);
                
                Console.WriteLine($"{DateTime.UtcNow:o} Producing message: {messageId}");

                var request = new SendMessageRequest
                {
                    QueueUrl = SqsQueueUrl,
                    MessageBody = messageContent
                    // REMOVED: MessageGroupId and MessageDeduplicationId are only for FIFO queues.
                };
                
                try
                {
                    var response = await SqsClient.SendMessageAsync(request);
                    Console.WriteLine($"{DateTime.UtcNow:o} Successfully sent message {messageId} with SQS MessageId {response.MessageId}");
                    activity?.SetTag("aws.sqs.message_id", response.MessageId);
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"{DateTime.UtcNow:o} Error sending message to SQS: {ex.Message}");
                    activity?.SetStatus(ActivityStatusCode.Error, "Failed to send to SQS");
                }
            }
            await Task.Delay(TimeSpan.FromMinutes(1));
        }
    }
}

// src/csharp-producer/Program.cs
using System.Diagnostics;
using Amazon.SQS;
using Amazon.SQS.Model;
using Serilog;

namespace DataProducer;

// Main entry point for the application.
public class Program
{
    public static void Main(string[] args)
    {
        // Configure Serilog for file and event log output.
        Log.Logger = new LoggerConfiguration()
            .MinimumLevel.Information()
            .Enrich.FromLogContext()
            .WriteTo.File(
                path: Path.Combine(AppContext.BaseDirectory, "logs", "service-.log"),
                rollingInterval: RollingInterval.Day,
                outputTemplate: "{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz} [{Level:u3}] {Message:lj}{NewLine}{Exception}")
            .WriteTo.EventLog("DataProducer", manageEventSource: true)
            .CreateLogger();

        try
        {
            Log.Information("--- Starting Service Host ---");
            CreateHostBuilder(args).Build().Run();
        }
        catch (Exception ex)
        {
            Log.Fatal(ex, "Host terminated unexpectedly");
        }
        finally
        {
            Log.CloseAndFlush();
        }
    }

    // Creates and configures the application host.
    public static IHostBuilder CreateHostBuilder(string[] args) =>
        Host.CreateDefaultBuilder(args)
            .UseSerilog() // Use Serilog for all logging
            .UseWindowsService(options =>
            {
                options.ServiceName = "DataProducer";
            })
            .ConfigureServices((hostContext, services) =>
            {
                services.AddHostedService<Worker>();
                services.AddSingleton<IAmazonSQS, AmazonSQSClient>();
            });
}

/// <summary>
/// The main worker service that runs in the background.
/// </summary>
internal class Worker : BackgroundService
{
    private readonly ILogger<Worker> _logger;
    private readonly IAmazonSQS _sqsClient;
    private static readonly ActivitySource MyActivitySource = new("DataProducer");
    private readonly string _sqsQueueUrl;
    private readonly IHostApplicationLifetime _hostApplicationLifetime;

    public Worker(ILogger<Worker> logger, IAmazonSQS sqsClient, IHostApplicationLifetime hostApplicationLifetime)
    {
        _logger = logger;
        _sqsClient = sqsClient;
        _hostApplicationLifetime = hostApplicationLifetime;
        _sqsQueueUrl = Environment.GetEnvironmentVariable("SQS_QUEUE_URL") ?? string.Empty;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        _logger.LogInformation("Worker service execution started.");

        if (string.IsNullOrEmpty(_sqsQueueUrl))
        {
            _logger.LogCritical("SQS_QUEUE_URL environment variable is not set or empty. The service cannot continue.");
            _hostApplicationLifetime.StopApplication();
            return;
        }
        
        _logger.LogInformation("Service configured to send messages to SQS Queue: {SqsQueueUrl}", _sqsQueueUrl);

        while (!stoppingToken.IsCancellationRequested)
        {
            _logger.LogInformation("Starting new message production cycle.");
            using (var activity = MyActivitySource.StartActivity("Produce new message"))
            {
                var messageId = Guid.NewGuid().ToString();
                var messageContent = $"Data generated at {DateTime.UtcNow:o}";
                
                activity?.SetTag("message.id", messageId);
                activity?.SetTag("message.content", messageContent);

                _logger.LogInformation("Generated new message with ID: {MessageId}", messageId);

                var request = new SendMessageRequest
                {
                    QueueUrl = _sqsQueueUrl,
                    MessageBody = messageContent
                };

                try
                {
                    _logger.LogInformation("Attempting to send message {MessageId} to SQS.", messageId);
                    var response = await _sqsClient.SendMessageAsync(request, stoppingToken);
                    _logger.LogInformation("Successfully sent message. SQS MessageId: {SqsMessageId}", response.MessageId);
                    activity?.SetTag("aws.sqs.message_id", response.MessageId);
                }
                catch (TaskCanceledException)
                {
                    _logger.LogWarning("Message sending was canceled as the service is stopping.");
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "An unexpected error occurred while sending message {MessageId} to SQS.", messageId);
                    activity?.SetStatus(ActivityStatusCode.Error, "Failed to send to SQS");
                }
            }

            try
            {
                _logger.LogInformation("Waiting for 3 seconds before next cycle.");
                await Task.Delay(TimeSpan.FromSeconds(3), stoppingToken);
            }
            catch (TaskCanceledException)
            {
                _logger.LogInformation("Delay was canceled as the service is stopping.");
            }
        }
        _logger.LogInformation("Worker service execution has finished.");
    }
}

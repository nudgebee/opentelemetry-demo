// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0

using Confluent.Kafka;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Npgsql;
using Oteldemo;
using Microsoft.EntityFrameworkCore;
using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace Accounting;

internal class DBContext : DbContext
{
    public DbSet<OrderEntity> Orders { get; set; }
    public DbSet<OrderItemEntity> CartItems { get; set; }
    public DbSet<ShippingEntity> Shipping { get; set; }

    protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
    {
        var connectionString = Environment.GetEnvironmentVariable("DB_CONNECTION_STRING");

        optionsBuilder.UseNpgsql(connectionString).UseSnakeCaseNamingConvention();
    }
}


internal class Consumer : BackgroundService
{
    private static readonly string TopicName = Environment.GetEnvironmentVariable("KAFKA_TOPIC") ?? "orders";

    private readonly ILogger _logger;
    private readonly IConsumer<string, byte[]> _consumer;
    private readonly string? _dbConnectionString;
    private static readonly ActivitySource MyActivitySource = new("Accounting.Consumer");
    private static readonly Meter MyMeter = new("Accounting.Consumer");
    private static readonly Counter<long> OrdersConsumed = MyMeter.CreateCounter<long>(
        "demo.accounting.orders.consumed", "{order}", "Order messages read from the orders topic");
    private static readonly Counter<long> OrdersRecorded = MyMeter.CreateCounter<long>(
        "demo.accounting.orders.recorded", "{order}", "Orders written to the accounting database");
    private static readonly Counter<long> OrdersDuplicate = MyMeter.CreateCounter<long>(
        "demo.accounting.orders.duplicates", "{order}", "Redelivered orders already in the accounting database");
    private static long _newestRecordedOrderTime;

    private readonly TimeSpan _replayWindow;
    private readonly Dictionary<string, DateTime> _recentOrders = new();

    public Consumer(ILogger<Consumer> logger)
    {
        _logger = logger;

        var servers = Environment.GetEnvironmentVariable("KAFKA_ADDR")
            ?? throw new InvalidOperationException("The KAFKA_ADDR environment variable is not set.");

        _consumer = BuildConsumer(servers);
        _consumer.Subscribe(TopicName);

        Log.KafkaConnecting(_logger, servers);

        _dbConnectionString = Environment.GetEnvironmentVariable("DB_CONNECTION_STRING");

        _replayWindow = int.TryParse(Environment.GetEnvironmentVariable("ORDER_REPLAY_WINDOW_SECONDS"), out var seconds)
            ? TimeSpan.FromSeconds(seconds)
            : TimeSpan.Zero;

        MyMeter.CreateObservableGauge(
            "demo.accounting.orders.newest_recorded_time",
            ObserveNewestRecordedOrderTime,
            "s",
            "Time the newest order in the accounting database was placed");

        // Report both counters from start-up, so an order written before the
        // first export is not lost to rate() and increase().
        OrdersConsumed.Add(0);
        OrdersRecorded.Add(0);
        OrdersDuplicate.Add(0);
    }

    private static IEnumerable<Measurement<long>> ObserveNewestRecordedOrderTime()
    {
        var newest = Interlocked.Read(ref _newestRecordedOrderTime);
        if (newest > 0)
        {
            yield return new Measurement<long>(newest);
        }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await Task.Yield();

        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    using var activity = MyActivitySource.StartActivity("order-consumed",  ActivityKind.Internal);
                    var consumeResult = _consumer.Consume(stoppingToken);
                    ProcessMessage(consumeResult.Message);
                }
                catch (ConsumeException e)
                {
                    Log.ConsumeError(_logger, e, e.Error.Reason);
                }
            }
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
        }
        finally
        {
            Log.ConsumerClosing(_logger);
            _consumer.Close();
        }
    }

    private void ProcessMessage(Message<string, byte[]> message)
    {
        try
        {
            var order = OrderResult.Parser.ParseFrom(message.Value);
            Log.OrderReceivedMessage(_logger, order);
            OrdersConsumed.Add(1);

            if (_dbConnectionString == null)
            {
                return;
            }

            if (IsReplay(order))
            {
                Log.ReplayedOrderSkipped(_logger, order.OrderId);
                return;
            }

            using var dbContext = new DBContext();
            var orderEntity = new OrderEntity
            {
                Id = order.OrderId
            };
            dbContext.Add(orderEntity);
            foreach (var item in order.Items)
            {
                var orderItem = new OrderItemEntity
                {
                    ItemCostCurrencyCode = item.Cost.CurrencyCode,
                    ItemCostUnits = item.Cost.Units,
                    ItemCostNanos = item.Cost.Nanos,
                    ProductId = item.Item.ProductId,
                    Quantity = item.Item.Quantity,
                    OrderId = order.OrderId
                };

                dbContext.Add(orderItem);
            }

            var shipping = new ShippingEntity
            {
                ShippingTrackingId = order.ShippingTrackingId,
                ShippingCostCurrencyCode = order.ShippingCost.CurrencyCode,
                ShippingCostUnits = order.ShippingCost.Units,
                ShippingCostNanos = order.ShippingCost.Nanos,
                StreetAddress = order.ShippingAddress.StreetAddress,
                City = order.ShippingAddress.City,
                State = order.ShippingAddress.State,
                Country = order.ShippingAddress.Country,
                ZipCode = order.ShippingAddress.ZipCode,
                OrderId = order.OrderId
            };
            dbContext.Add(shipping);
            dbContext.SaveChanges();

            OrdersRecorded.Add(1);
            RememberOrder(order);
            var placedAt = message.Timestamp.Type == TimestampType.NotAvailable
                ? DateTimeOffset.UtcNow.ToUnixTimeSeconds()
                : message.Timestamp.UnixTimestampMs / 1000;
            if (placedAt > Interlocked.Read(ref _newestRecordedOrderTime))
            {
                Interlocked.Exchange(ref _newestRecordedOrderTime, placedAt);
            }
        }
        catch (DbUpdateException ex) when (ex.InnerException is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
        {
            OrdersDuplicate.Add(1);
            Log.DuplicateOrderSkipped(_logger);
        }
        catch (Exception ex)
        {
            Log.OrderParsingFailed(_logger, ex);
        }
    }

    private bool IsReplay(OrderResult order)
    {
        if (_replayWindow == TimeSpan.Zero)
        {
            return false;
        }

        var now = DateTime.UtcNow;
        foreach (var stale in _recentOrders.Where(e => now - e.Value > _replayWindow).Select(e => e.Key).ToList())
        {
            _recentOrders.Remove(stale);
        }

        return _recentOrders.ContainsKey(ReplayKey(order));
    }

    private void RememberOrder(OrderResult order)
    {
        if (_replayWindow != TimeSpan.Zero)
        {
            _recentOrders[ReplayKey(order)] = DateTime.UtcNow;
        }
    }

    private static string ReplayKey(OrderResult order)
    {
        var address = order.ShippingAddress;
        return $"{address.StreetAddress}|{address.City}|{address.ZipCode}|{address.Country}";
    }

    private static IConsumer<string, byte[]> BuildConsumer(string servers)
    {
        var conf = new ConsumerConfig
        {
            GroupId = "accounting",
            BootstrapServers = servers,
            // https://github.com/confluentinc/confluent-kafka-dotnet/tree/07de95ed647af80a0db39ce6a8891a630423b952#basic-consumer-example
            AutoOffsetReset = AutoOffsetReset.Earliest,
            EnableAutoCommit = true
        };

        return new ConsumerBuilder<string, byte[]>(conf)
            .Build();
    }

    public override void Dispose()
    {
        _consumer?.Dispose();
        base.Dispose();
    }
}

IF DB_ID(N'modular_api_graphql_v1') IS NULL
BEGIN
    CREATE DATABASE [modular_api_graphql_v1];
END;
GO

USE [modular_api_graphql_v1];
GO

IF SCHEMA_ID(N'sales') IS NULL
BEGIN
    EXEC(N'CREATE SCHEMA sales');
END;
GO

IF OBJECT_ID(N'sales.vw_OrderSummary', N'V') IS NOT NULL
BEGIN
    DROP VIEW sales.vw_OrderSummary;
END;
GO

IF OBJECT_ID(N'sales.[Order]', N'U') IS NOT NULL
BEGIN
    DROP TABLE sales.[Order];
END;
GO

IF OBJECT_ID(N'sales.Customer', N'U') IS NOT NULL
BEGIN
    DROP TABLE sales.Customer;
END;
GO

CREATE TABLE sales.Customer (
    CustomerId INT IDENTITY(1, 1) NOT NULL,
    CustomerCode NVARCHAR(20) NOT NULL,
    FullName NVARCHAR(120) NOT NULL,
    CreatedAt DATETIME2 NOT NULL,
    IsActive BIT NOT NULL,
    CONSTRAINT PK_Customer PRIMARY KEY CLUSTERED (CustomerId),
    CONSTRAINT UQ_Customer_CustomerCode UNIQUE (CustomerCode)
);
GO

CREATE TABLE sales.[Order] (
    OrderId UNIQUEIDENTIFIER NOT NULL,
    CustomerId INT NOT NULL,
    TotalAmount DECIMAL(18, 2) NOT NULL,
    Notes NVARCHAR(200) NULL,
    CreatedAt DATETIME2 NOT NULL,
    CONSTRAINT PK_Order PRIMARY KEY CLUSTERED (OrderId),
    CONSTRAINT FK_Order_Customer FOREIGN KEY (CustomerId)
        REFERENCES sales.Customer (CustomerId)
);
GO

INSERT INTO sales.Customer (CustomerCode, FullName, CreatedAt, IsActive)
VALUES
    (N'CUST-001', N'Ada Lovelace', '2026-01-15T08:30:00', 1),
    (N'CUST-002', N'Grace Hopper', '2026-01-16T09:15:00', 1);
GO

INSERT INTO sales.[Order] (OrderId, CustomerId, TotalAmount, Notes, CreatedAt)
VALUES
    ('11111111-1111-1111-1111-111111111111', 1, 120.50, N'priority order', '2026-01-20T10:00:00'),
    ('22222222-2222-2222-2222-222222222222', 2, 89.99, NULL, '2026-01-21T11:15:00');
GO

CREATE VIEW sales.vw_OrderSummary
AS
SELECT
    o.OrderId,
    o.CustomerId,
    c.CustomerCode,
    c.FullName,
    o.TotalAmount,
    CAST(CASE WHEN o.Notes IS NULL THEN 0 ELSE 1 END AS BIT) AS HasNotes,
    o.CreatedAt
FROM sales.[Order] AS o
INNER JOIN sales.Customer AS c
    ON c.CustomerId = o.CustomerId;
GO
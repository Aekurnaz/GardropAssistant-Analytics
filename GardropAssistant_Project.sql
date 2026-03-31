------------------------------------------------------------

-- 1. Adding a 'Ghost' System User to the system
INSERT INTO users (id, email, username, age, gender, onboardingComplete, bodyType, createdAt)
VALUES (
    '00000000-0000-0000-0000-000000000000', -- Special System ID
    'system@smartwardrobe.app', 
    'System_Account', 
    99, -- An extreme age value that is easy to filter out in analytics
    'System', 
    1, 
    'None', 
    GETDATE()
);


-- 2. Updating the owner of the previously created Dummy Event to this System User
UPDATE events
    SET userId = '00000000-0000-0000-0000-000000000000'
WHERE id = '00000000-0000-0000-0000-000000000000';


------------------------------------------------------------------------------

--## Wardrobe Economics View -- 
CREATE VIEW vw_UserWardrobeEconomics AS
WITH UserTopStyle AS (
    -- Find the most frequently worn style for each user using Window Functions
    SELECT 
        userId, 
        style,
        ROW_NUMBER() OVER(PARTITION BY userId ORDER BY COUNT(*) DESC) as style_rank
    FROM garments
    GROUP BY userId, style
)
-- Using TOP (100) PERCENT to allow ORDER BY within the view
SELECT TOP (100) PERCENT
    u.id AS UserId,
    u.age AS Age,
    u.bodyType AS BodyType,
    COUNT(g.id) AS TotalGarments,
    SUM(g.price) AS TotalWardrobeValue,
    ROUND(SUM(g.price) / NULLIF(SUM(g.wearCount), 0), 2) AS AverageCostPerWear,
    uts.style AS FavoriteStyle
FROM users u
LEFT JOIN garments g ON u.id = g.userId
LEFT JOIN UserTopStyle uts ON u.id = uts.userId AND uts.style_rank = 1
GROUP BY 
    u.id, 
    u.age, 
    u.bodyType, 
    uts.style
ORDER BY TotalGarments DESC;


-------------------------------------------------------------------------

--## RFM Analysis View

CREATE VIEW vw_UserRFM_Analysis AS
WITH UserStats AS (
    --Calculate Recency, Frequency, and Monetary metrics per user
    SELECT 
        u.id AS userId,
        u.username,
        DATEDIFF(day, MAX(g.lastWornAt), GETDATE()) AS DaysSinceLastWear -- Recency: Days since the last worn item,        
        SUM(g.wearCount) AS TotalWears -- Frequency: Total number of times garments were worn ,        
        SUM(g.price) AS TotalSpent -- Monetary: Total value of the wardrobe
    FROM users u
    JOIN garments g ON u.id = g.userId
    GROUP BY u.id, u.username
),
RFM_Scores AS (
    --Divide each metric into quartiles (1-4) using NTILE
    SELECT 
        userId,
        username,
        DaysSinceLastWear,
        TotalWears,
        TotalSpent,
        -- Recency is inversely proportional: fewer days get a higher score (4)
        NTILE(4) OVER (ORDER BY DaysSinceLastWear DESC) AS R_Score,
        NTILE(4) OVER (ORDER BY TotalWears ASC) AS F_Score,
        NTILE(4) OVER (ORDER BY TotalSpent ASC) AS M_Score
    FROM UserStats
    WHERE TotalSpent > 0 AND TotalWears > 0
)
--Combine scores and assign customer segments
SELECT 
    userId,
    username,
    R_Score, F_Score, M_Score,
    
    CAST(R_Score AS VARCHAR) + CAST(F_Score AS VARCHAR) + CAST(M_Score AS VARCHAR) AS RFM_Cell,
    CASE 
        WHEN R_Score >= 3 AND F_Score >= 3 AND M_Score >= 3 THEN 'Champions'
        WHEN R_Score >= 3 AND F_Score <= 2 THEN 'Recent & Potential'
        WHEN R_Score <= 2 AND F_Score >= 3 THEN 'At Risk Loyal Customers'
        ELSE 'Lost / Low Engagement'
    END AS CustomerSegment
FROM RFM_Scores;


-----------------------------------------------------

--## Cumulative Running Total View

CREATE VIEW vw_CumulativeWardrobeInvestment AS
WITH MonthlySpending AS (
    -- Step 1: Calculate the total amount spent per user per month
    SELECT 
        userId,
        YEAR(createdAt) AS BuyYear,
        MONTH(createdAt) AS BuyMonth,
        SUM(price) AS MonthlySpent
    FROM garments
    GROUP BY userId, YEAR(createdAt), MONTH(createdAt)
)
SELECT 
    userId,
    BuyYear,
    BuyMonth,
    MonthlySpent,
    -- Step 2: Running Total (Cumulative total spent up to that month)
    SUM(MonthlySpent) OVER (
        PARTITION BY userId 
        ORDER BY BuyYear, BuyMonth 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS CumulativeTotalSpent
FROM MonthlySpending;



--------------------------------------------------------

--Day-30 Event Retention Rate

CREATE VIEW vw_KPI_Day30Retention AS
WITH CohortUsers AS(
SELECT COUNT(id) as TotalUserLast30Days
from users
where createdAt <= DATEADD(DAY, -30, GETDATE())
),
RetainedUsers AS (
SELECT COUNT(DISTINCT e.userId) AS RetainedCount
from users u
left join events e on u.id = e.userID 
WHERE u.createdAt <= DATEADD(DAY, -30, GETDATE()) AND e.date >= DATEADD(DAY, 30, u.createdAt)
)
SELECT 
	(CAST(r.RetainedCount as float) / NULLIF(c.TotalUserLast30Days,0)) as Day30EventRetentionRate
FROM CohortUsers c, RetainedUsers r

--------------------------------------------------------

--DAU / MAU Ratio

CREATE VIEW vw_KPI_Daily_Monthly_Ratio AS
WITH DailyActives AS (
    -- Distinct users per day over the last 30 days
    SELECT date, COUNT(DISTINCT userId) AS DAU
    FROM events
    WHERE date >= DATEADD(day, -30, GETDATE())
    GROUP BY date
),
AvgDAU AS (   
    SELECT AVG(CAST(DAU AS FLOAT)) AS AvgDailyActive
    FROM DailyActives
),
MonthlyActives AS (    
    SELECT COUNT(DISTINCT userId) AS MAU
    FROM events
    WHERE date >= DATEADD(day, -30, GETDATE())
)
SELECT 
    a.AvgDailyActive / NULLIF(m.MAU, 0) AS DAUMAU_Ratio
FROM AvgDAU a, MonthlyActives m;

----------------------------------------------------

--Average Days Between Events

CREATE VIEW vw_KPI_AvgDaysBetweenEvents AS
WITH UserEventStats AS (
    SELECT 
        userId,
        DATEDIFF(day, MIN(date), MAX(date)) AS ActiveDays,
        COUNT(id) - 1 AS Intervals 
    FROM events
    GROUP BY userId
    HAVING COUNT(id) > 1 -- Only consider users with at least 2 events
)
SELECT 
    AVG(CAST(ActiveDays AS FLOAT) / NULLIF(Intervals, 0)) AS AvgDaysBetweenEvents
FROM UserEventStats;

----------------------------------------------

--Estimated Churn Rate(Event Crate)

CREATE VIEW vw_KPI_EstimatedChurn AS
WITH UserStatus AS (
    SELECT 
        u.id,
        MAX(e.date) AS LastEventDate
    FROM users u
    LEFT JOIN events e ON u.id = e.userId
    GROUP BY u.id
)
SELECT 
    SUM(CASE WHEN LastEventDate < DATEADD(day, -60, GETDATE()) OR LastEventDate IS NULL THEN 1 ELSE 0 END) * 1.0 
    / NULLIF(COUNT(id), 0) AS EstimatedChurnRate
FROM UserStatus;
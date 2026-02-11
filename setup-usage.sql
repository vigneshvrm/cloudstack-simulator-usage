-- Enable the CloudStack Usage Server and configure for dev/testing
-- This script runs during Docker image build after database deployment

USE cloud;

-- Enable the usage server
UPDATE configuration SET value = 'true' WHERE name = 'enable.usage.server';

-- Set aggregation range to 5 minutes for faster testing (default is 1440 = daily)
UPDATE configuration SET value = '5' WHERE name = 'usage.stats.job.aggregation.range';

-- Set execution time to run soon after startup (HH:MM format, 24hr)
UPDATE configuration SET value = '00:00' WHERE name = 'usage.stats.job.exec.time';

-- Verify settings
SELECT name, value FROM configuration WHERE name LIKE 'usage%' OR name = 'enable.usage.server';


/*
  # Seed Initial Data
  
  ## Inserts
  - 10 major US cities
  - 20 system tags for AI classification
  - 5 sample events for development
  
  All seed data is idempotent (uses ON CONFLICT DO NOTHING)
*/

-- =============================================
-- SEED: Cities
-- =============================================
INSERT INTO cities (name, state, country, slug, latitude, longitude, timezone) VALUES
  ('New York',      'NY', 'US', 'new-york',      40.7128,  -74.0060,  'America/New_York'),
  ('Los Angeles',   'CA', 'US', 'los-angeles',   34.0522,  -118.2437, 'America/Los_Angeles'),
  ('Chicago',       'IL', 'US', 'chicago',       41.8781,  -87.6298,  'America/Chicago'),
  ('San Francisco', 'CA', 'US', 'san-francisco',  37.7749, -122.4194, 'America/Los_Angeles'),
  ('Austin',        'TX', 'US', 'austin',         30.2672,  -97.7431, 'America/Chicago'),
  ('Boston',        'MA', 'US', 'boston',         42.3601,  -71.0589, 'America/New_York'),
  ('Seattle',       'WA', 'US', 'seattle',        47.6062, -122.3321, 'America/Los_Angeles'),
  ('Denver',        'CO', 'US', 'denver',         39.7392, -104.9903, 'America/Denver'),
  ('Miami',         'FL', 'US', 'miami',          25.7617,  -80.1918, 'America/New_York'),
  ('Portland',      'OR', 'US', 'portland',       45.5051, -122.6750, 'America/Los_Angeles'),
  ('Baton Rouge',   'LA', 'US', 'baton-rouge',    30.4515,  -91.1871, 'America/Chicago'),
  ('Louisville',    'KY', 'US', 'louisville',     38.2527,  -85.7585, 'America/New_York')
ON CONFLICT (slug) DO NOTHING;

-- =============================================
-- SEED: Tags
-- =============================================
INSERT INTO tags (name, slug, color, category, is_system) VALUES
  ('Free',               'free',               '#16a34a', 'cost',     true),
  ('Outdoor',            'outdoor',            '#15803d', 'location', true),
  ('Indoor',             'indoor',             '#0369a1', 'location', true),
  ('Toddler-Friendly',   'toddler-friendly',   '#d97706', 'age',      true),
  ('Baby-Friendly',      'baby-friendly',      '#f59e0b', 'age',      true),
  ('Teen-Friendly',      'teen-friendly',      '#7c3aed', 'age',      true),
  ('Weekend',            'weekend',            '#db2777', 'time',     true),
  ('Educational',        'educational',        '#0284c7', 'theme',    true),
  ('Arts & Crafts',      'arts-crafts',        '#c026d3', 'activity', true),
  ('Music',              'music',              '#ea580c', 'activity', true),
  ('Sensory-Friendly',   'sensory-friendly',   '#0891b2', 'theme',    true),
  ('Family Festival',    'family-festival',    '#dc2626', 'theme',    true),
  ('Storytime',          'storytime',          '#65a30d', 'activity', true),
  ('STEM',               'stem',               '#2563eb', 'theme',    true),
  ('Sports',             'sports',             '#16a34a', 'activity', true),
  ('Cooking',            'cooking',            '#d97706', 'activity', true),
  ('Nature',             'nature',             '#15803d', 'theme',    true),
  ('Community',          'community',          '#6d28d9', 'theme',    true),
  ('Holiday',            'holiday',            '#dc2626', 'theme',    true),
  ('Playgroup',          'playgroup',          '#0891b2', 'activity', true)
ON CONFLICT (slug) DO NOTHING;

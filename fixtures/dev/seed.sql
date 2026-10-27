-- Only the isolated Compose fixture database.
CREATE TABLE IF NOT EXISTS synthetic_records (id integer PRIMARY KEY, label text NOT NULL);
INSERT INTO synthetic_records VALUES (1, 'alpha'), (2, 'beta'), (3, 'gamma') ON CONFLICT (id) DO NOTHING;

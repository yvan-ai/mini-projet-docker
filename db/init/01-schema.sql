CREATE TABLE IF NOT EXISTS tasks (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title       VARCHAR(200) NOT NULL CHECK (char_length(btrim(title)) > 0),
    done        BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    done_at     TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_tasks_done_created ON tasks (done, created_at DESC);

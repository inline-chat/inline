-- Turn on global search capture. The function locks messages and documents
-- briefly; the migrator's 5 s lock_timeout fails the release rather than
-- queueing behind traffic. A no-op when capture is already on.
SELECT inline_search_set_capture(true);

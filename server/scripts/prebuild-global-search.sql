-- Run with psql on the direct endpoint before 0176 on a populated database.
-- Each build must run in its own transaction. If interrupted, inspect the named
-- index in pg_index. Drop an invalid build CONCURRENTLY before retrying.
\set ON_ERROR_STOP on
CREATE INDEX CONCURRENTLY IF NOT EXISTS "messages_chat_search_date_idx" ON "messages" USING btree ("chat_id","date" DESC NULLS LAST,"global_id" DESC NULLS LAST);
CREATE INDEX CONCURRENTLY IF NOT EXISTS "messages_document_id_idx" ON "messages" USING btree ("document_id") WHERE "messages"."document_id" is not null;

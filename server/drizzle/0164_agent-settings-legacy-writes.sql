-- Old API instances still write the runtime's output mode during a rolling
-- deploy or rollback. Keep those writes in the new settings table.
CREATE FUNCTION public.sync_legacy_agent_output_mode() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  saved_mode smallint;
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- An old first heartbeat must not reset settings made before the runtime.
    SELECT default_output_mode INTO saved_mode
      FROM public.agent_settings WHERE bot_user_id = NEW.bot_user_id;
    IF FOUND THEN
      NEW.default_output_mode := saved_mode;
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.default_output_mode IS DISTINCT FROM OLD.default_output_mode THEN
    INSERT INTO public.agent_settings AS settings
      (bot_user_id, default_output_mode, updated_at)
    VALUES (NEW.bot_user_id, NEW.default_output_mode, NEW.updated_at)
    ON CONFLICT (bot_user_id) DO UPDATE SET
      default_output_mode = EXCLUDED.default_output_mode,
      revision = settings.revision + 1,
      updated_by = NULL,
      updated_at = EXCLUDED.updated_at
    WHERE settings.default_output_mode IS DISTINCT FROM EXCLUDED.default_output_mode;
  END IF;
  RETURN NEW;
END;
$$;
--> statement-breakpoint
CREATE TRIGGER agent_runtime_inherit_output_mode
BEFORE INSERT ON public.agent_runtimes
FOR EACH ROW EXECUTE FUNCTION public.sync_legacy_agent_output_mode();
--> statement-breakpoint
CREATE TRIGGER agent_runtime_preserve_legacy_output_mode
AFTER UPDATE OF default_output_mode ON public.agent_runtimes
FOR EACH ROW EXECUTE FUNCTION public.sync_legacy_agent_output_mode();
--> statement-breakpoint
-- Trigger creation locks runtime writes until this migration commits. Repair
-- writes that arrived after 0163's one-time seed while holding that same lock.
INSERT INTO public.agent_settings AS settings (bot_user_id, default_output_mode)
SELECT runtime.bot_user_id, runtime.default_output_mode
FROM public.agent_runtimes AS runtime
LEFT JOIN public.agent_settings AS saved ON saved.bot_user_id = runtime.bot_user_id
WHERE runtime.default_output_mode <> 0 OR saved.bot_user_id IS NOT NULL
ON CONFLICT (bot_user_id) DO UPDATE SET
  default_output_mode = EXCLUDED.default_output_mode,
  revision = settings.revision + 1,
  updated_by = NULL,
  updated_at = now()
WHERE settings.default_output_mode IS DISTINCT FROM EXCLUDED.default_output_mode;

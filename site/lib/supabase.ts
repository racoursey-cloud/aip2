import { createClient, type SupabaseClient } from '@supabase/supabase-js';

/**
 * Server-side Supabase client.
 *
 * Every table in this project is RLS deny-all with no policies, so reads happen as
 * service_role, which carries BYPASSRLS. That key must never reach a browser: it has no
 * NEXT_PUBLIC_ prefix, and this module is imported only from server components and route
 * handlers. The `server-only` guard below turns a mistaken client import into a build error
 * rather than a leaked credential.
 */
import 'server-only';

let client: SupabaseClient | null = null;

export function supabaseServer(): SupabaseClient {
  if (client) return client;

  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) {
    throw new Error(
      'SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set. See site/.env.example.',
    );
  }

  client = createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return client;
}

/** True when the site has been given database credentials at all. */
export function hasDatabaseConfig(): boolean {
  return Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY);
}

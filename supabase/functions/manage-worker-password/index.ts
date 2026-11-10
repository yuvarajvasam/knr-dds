import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const ALLOWED_WORKERS = ["govardhini", "rajashyamala"] as const;
type AllowedWorker = typeof ALLOWED_WORKERS[number];

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const token = authHeader.replace("Bearer ", "").trim();
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

    if (!supabaseUrl || !supabaseServiceKey) {
      return new Response(JSON.stringify({ error: "Server configuration error" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 1. Verify caller with auth client
    const userClient = createClient(supabaseUrl, supabaseAnonKey || supabaseServiceKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false },
    });

    const { data: { user: callerUser }, error: callerError } = await userClient.auth.getUser(token);
    if (callerError || !callerUser) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 2. Verify caller role is owner in trusted public.profiles table using admin client
    const adminClient = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { persistSession: false },
    });

    const { data: callerProfile, error: profileError } = await adminClient
      .from("profiles")
      .select("role")
      .eq("id", callerUser.id)
      .maybeSingle();

    if (profileError || !callerProfile || callerProfile.role !== "owner") {
      return new Response(JSON.stringify({ error: "Forbidden: Owner access required" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 3. Parse and validate request body
    const body = await req.json().catch(() => null);
    if (!body || typeof body !== "object") {
      return new Response(JSON.stringify({ error: "Invalid request payload" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { worker, new_password, confirm_password } = body;

    // Strict validation of allowed worker account
    if (!worker || !ALLOWED_WORKERS.includes(worker as AllowedWorker)) {
      return new Response(JSON.stringify({ error: "Invalid target account. Can only update govardhini or rajashyamala." }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (!new_password || typeof new_password !== "string" || new_password.length < 8) {
      return new Response(JSON.stringify({ error: "Password must be at least 8 characters long." }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (new_password !== confirm_password) {
      return new Response(JSON.stringify({ error: "Password and confirmation do not match." }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 4. Look up target worker user in auth.users by synthetic email
    const targetEmail = `${worker}@diarynote.internal`;
    const { data: { users: targetUsers }, error: searchError } = await adminClient.auth.admin.listUsers();
    if (searchError || !targetUsers) {
      return new Response(JSON.stringify({ error: "Failed to locate worker account" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const targetUser = targetUsers.find((u) => u.email?.toLowerCase() === targetEmail.toLowerCase());
    if (!targetUser) {
      return new Response(JSON.stringify({ error: `Worker user ${worker} not found.` }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 5. Update worker password using admin API
    const { error: updateError } = await adminClient.auth.admin.updateUserById(targetUser.id, {
      password: new_password,
    });

    if (updateError) {
      return new Response(JSON.stringify({ error: "Failed to update password." }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ success: true, message: `Password for ${worker} updated successfully.` }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (_err) {
    return new Response(JSON.stringify({ error: "Internal server error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});


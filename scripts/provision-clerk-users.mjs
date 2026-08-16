#!/usr/bin/env node
// U19: Clerk account provisioning and identity mapping.
//
// For every existing Supabase auth user, ensure (a) a Clerk account exists
// for their email, (b) the account carries the right role in public metadata
// (user_profiles.role admin -> operator, else member), and (c) a row exists
// in public.clerk_user_mapping. Additive and idempotent: re-running never
// creates duplicate Clerk accounts or mapping rows. Potential duplicate
// emails (case variants, plus-addressing) are SURFACED and skipped — merging
// identities is an explicit operator decision, never automatic.
//
// Usage:
//   node scripts/provision-clerk-users.mjs             # dry-run: print the plan
//   node scripts/provision-clerk-users.mjs --apply     # execute the plan
//   node scripts/provision-clerk-users.mjs --reconcile # diff mapping table vs Clerk
//
// Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (always);
//      CLERK_SECRET_KEY (required for --apply/--reconcile; dry-run without it
//      assumes no pre-existing Clerk users and says so).

// ─── Pure planning logic (unit-tested in tests/provision-clerk-users.test.mjs) ───

export function normalizeEmail(email) {
  return String(email ?? "")
    .trim()
    .toLowerCase()
}

/**
 * Collision key for surfacing probable same-person emails: lowercase and
 * strip a +tag from the local part. Used only to REPORT duplicates.
 */
export function emailCollisionKey(email) {
  const normalized = normalizeEmail(email)
  const at = normalized.lastIndexOf("@")
  if (at < 0) return normalized
  const local = normalized.slice(0, at).replace(/\+.*$/, "")
  return `${local}@${normalized.slice(at + 1)}`
}

export function mapRole(profileRole) {
  return profileRole === "admin" ? "operator" : "member"
}

/**
 * Computes the provisioning plan.
 *
 * @param {object} input
 * @param {Array<{id: string, email: string}>} input.authUsers
 * @param {Map<string, {role?: string}>} input.profilesById
 * @param {Array<{clerk_user_id: string, supabase_uuid: string}>} input.mappings
 * @param {Map<string, {id: string}>} input.clerkUsersByEmail normalized email -> Clerk user
 */
export function buildProvisioningPlan({ authUsers, profilesById, mappings, clerkUsersByEmail }) {
  const mappedUuids = new Set(mappings.map((m) => m.supabase_uuid))

  const byCollisionKey = new Map()
  for (const user of authUsers) {
    if (!user.email) continue
    const key = emailCollisionKey(user.email)
    const group = byCollisionKey.get(key) ?? []
    group.push(user)
    byCollisionKey.set(key, group)
  }
  const duplicates = [...byCollisionKey.values()].filter((group) => group.length > 1)
  const duplicateIds = new Set(duplicates.flat().map((u) => u.id))

  const noEmail = []
  const alreadyMapped = []
  const toLink = []
  const toCreate = []

  for (const user of authUsers) {
    if (!user.email) {
      noEmail.push(user)
      continue
    }
    if (duplicateIds.has(user.id)) continue
    if (mappedUuids.has(user.id)) {
      alreadyMapped.push(user)
      continue
    }
    const role = mapRole(profilesById.get(user.id)?.role)
    const email = normalizeEmail(user.email)
    const existingClerkUser = clerkUsersByEmail.get(email)
    if (existingClerkUser) {
      toLink.push({ user, email, role, clerkUserId: existingClerkUser.id })
    } else {
      toCreate.push({ user, email, role })
    }
  }

  return { duplicates, noEmail, alreadyMapped, toLink, toCreate }
}

// ─── IO ──────────────────────────────────────────────────────────────────────

const SUPABASE_URL = (process.env.SUPABASE_URL ?? "").replace(/\/$/, "")
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY ?? ""
const CLERK_KEY = process.env.CLERK_SECRET_KEY ?? ""
const CLERK_API = "https://api.clerk.com/v1"

function supabaseHeaders() {
  return { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` }
}

async function getJson(url, headers) {
  const res = await fetch(url, { headers })
  if (!res.ok) throw new Error(`GET ${url} -> ${res.status}: ${await res.text()}`)
  return res.json()
}

async function fetchAllAuthUsers() {
  const users = []
  for (let page = 1; ; page++) {
    const body = await getJson(
      `${SUPABASE_URL}/auth/v1/admin/users?page=${page}&per_page=200`,
      supabaseHeaders()
    )
    const batch = body.users ?? []
    users.push(...batch.map((u) => ({ id: u.id, email: u.email ?? null })))
    if (batch.length < 200) return users
  }
}

async function fetchProfiles() {
  const rows = await getJson(
    `${SUPABASE_URL}/rest/v1/user_profiles?select=id,role`,
    supabaseHeaders()
  )
  return new Map(rows.map((r) => [r.id, r]))
}

async function fetchMappings() {
  return getJson(
    `${SUPABASE_URL}/rest/v1/clerk_user_mapping?select=clerk_user_id,supabase_uuid,email,role`,
    supabaseHeaders()
  )
}

async function fetchClerkUsers() {
  const byEmail = new Map()
  const all = []
  for (let offset = 0; ; offset += 100) {
    const batch = await getJson(`${CLERK_API}/users?limit=100&offset=${offset}`, {
      Authorization: `Bearer ${CLERK_KEY}`,
    })
    for (const u of batch) {
      all.push(u)
      for (const addr of u.email_addresses ?? []) {
        byEmail.set(normalizeEmail(addr.email_address), u)
      }
    }
    if (batch.length < 100) return { byEmail, all }
  }
}

async function createClerkUser(email, role) {
  const res = await fetch(`${CLERK_API}/users`, {
    method: "POST",
    headers: { Authorization: `Bearer ${CLERK_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      email_address: [email],
      public_metadata: { role },
      skip_password_requirement: true,
    }),
  })
  if (!res.ok) throw new Error(`Clerk create ${email} -> ${res.status}: ${await res.text()}`)
  return res.json()
}

async function upsertMapping(row) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/clerk_user_mapping`, {
    method: "POST",
    headers: {
      ...supabaseHeaders(),
      "Content-Type": "application/json",
      Prefer: "resolution=merge-duplicates",
    },
    body: JSON.stringify(row),
  })
  if (!res.ok) throw new Error(`mapping upsert ${row.email} -> ${res.status}: ${await res.text()}`)
}

async function main() {
  const args = new Set(process.argv.slice(2))
  const apply = args.has("--apply")
  const reconcile = args.has("--reconcile")

  if (!SUPABASE_URL || !SERVICE_KEY) {
    console.error("error: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required")
    process.exit(1)
  }
  if ((apply || reconcile) && !CLERK_KEY) {
    console.error("error: CLERK_SECRET_KEY is required for --apply/--reconcile")
    process.exit(1)
  }

  const [authUsers, profilesById, mappings] = await Promise.all([
    fetchAllAuthUsers(),
    fetchProfiles(),
    fetchMappings(),
  ])

  if (reconcile) {
    const { all } = await fetchClerkUsers()
    const clerkIds = new Set(all.map((u) => u.id))
    const mappedIds = new Set(mappings.map((m) => m.clerk_user_id))
    const missingInClerk = mappings.filter((m) => !clerkIds.has(m.clerk_user_id))
    const extraInClerk = all.filter((u) => !mappedIds.has(u.id))
    console.log(`reconcile: ${mappings.length} mapping rows, ${all.length} Clerk users`)
    for (const m of missingInClerk)
      console.log(`  MISSING in Clerk: ${m.clerk_user_id} (${m.email})`)
    for (const u of extraInClerk) console.log(`  EXTRA in Clerk (no mapping row): ${u.id}`)
    process.exit(missingInClerk.length || extraInClerk.length ? 1 : 0)
  }

  let clerkUsersByEmail = new Map()
  if (CLERK_KEY) {
    clerkUsersByEmail = (await fetchClerkUsers()).byEmail
  } else {
    console.log("note: CLERK_SECRET_KEY not set — dry-run assumes no existing Clerk users")
  }

  const plan = buildProvisioningPlan({ authUsers, profilesById, mappings, clerkUsersByEmail })

  console.log(`auth users: ${authUsers.length}`)
  console.log(`already mapped (skipped): ${plan.alreadyMapped.length}`)
  console.log(`without email (skipped): ${plan.noEmail.length}`)
  for (const group of plan.duplicates) {
    console.log(
      `DUPLICATE (operator merge decision needed, skipped): ${group
        .map((u) => `${u.email} [${u.id}]`)
        .join(" <-> ")}`
    )
  }
  for (const item of plan.toLink) {
    console.log(`link: ${item.email} -> existing Clerk ${item.clerkUserId} (role=${item.role})`)
  }
  for (const item of plan.toCreate) {
    console.log(`create: ${item.email} (role=${item.role})`)
  }

  if (!apply) {
    console.log("\ndry-run complete; re-run with --apply to execute")
    return
  }

  for (const item of plan.toLink) {
    await upsertMapping({
      clerk_user_id: item.clerkUserId,
      supabase_uuid: item.user.id,
      email: item.email,
      role: item.role,
    })
    console.log(`linked ${item.email}`)
  }
  for (const item of plan.toCreate) {
    const created = await createClerkUser(item.email, item.role)
    await upsertMapping({
      clerk_user_id: created.id,
      supabase_uuid: item.user.id,
      email: item.email,
      role: item.role,
    })
    console.log(`created ${item.email} -> ${created.id}`)
  }
  console.log("apply complete; run --reconcile to verify")
}

const isDirectRun = process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href
if (isDirectRun) {
  main().catch((err) => {
    console.error(err)
    process.exit(1)
  })
}

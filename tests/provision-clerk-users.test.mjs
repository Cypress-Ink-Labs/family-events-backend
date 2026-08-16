// U19: unit tests for the provisioning planner (scripts/provision-clerk-users.mjs).
// Covers the plan's scenarios: duplicate emails surfaced (not merged),
// idempotent re-runs, linking to pre-existing Clerk accounts, role mapping.

import assert from "node:assert/strict"
import { test } from "node:test"
import {
  buildProvisioningPlan,
  emailCollisionKey,
  mapRole,
  normalizeEmail,
} from "../scripts/provision-clerk-users.mjs"

const u = (id, email) => ({ id, email })

test("email normalization and collision keys", () => {
  assert.equal(normalizeEmail("  Jane@Example.COM "), "jane@example.com")
  assert.equal(emailCollisionKey("Jane+kids@Example.com"), "jane@example.com")
  assert.equal(emailCollisionKey("jane@example.com"), "jane@example.com")
  assert.notEqual(emailCollisionKey("jane@other.com"), emailCollisionKey("jane@example.com"))
})

test("role mapping: admin -> operator, everything else -> member", () => {
  assert.equal(mapRole("admin"), "operator")
  assert.equal(mapRole("user"), "member")
  assert.equal(mapRole(undefined), "member")
})

test("case-variant and plus-addressed duplicates are surfaced and skipped", () => {
  const plan = buildProvisioningPlan({
    authUsers: [
      u("a1", "Jane@example.com"),
      u("a2", "jane+alt@example.com"),
      u("b1", "bob@example.com"),
    ],
    profilesById: new Map(),
    mappings: [],
    clerkUsersByEmail: new Map(),
  })
  assert.equal(plan.duplicates.length, 1)
  assert.deepEqual(plan.duplicates[0].map((x) => x.id).sort(), ["a1", "a2"])
  // Duplicates are never provisioned automatically.
  assert.deepEqual(
    plan.toCreate.map((x) => x.user.id),
    ["b1"]
  )
  assert.equal(plan.toLink.length, 0)
})

test("re-running with mapping rows present is idempotent (no creates)", () => {
  const authUsers = [u("a1", "jane@example.com"), u("b1", "bob@example.com")]
  const mappings = [
    { clerk_user_id: "user_1", supabase_uuid: "a1" },
    { clerk_user_id: "user_2", supabase_uuid: "b1" },
  ]
  const plan = buildProvisioningPlan({
    authUsers,
    profilesById: new Map(),
    mappings,
    clerkUsersByEmail: new Map(),
  })
  assert.equal(plan.toCreate.length, 0)
  assert.equal(plan.toLink.length, 0)
  assert.deepEqual(plan.alreadyMapped.map((x) => x.id).sort(), ["a1", "b1"])
})

test("a pre-existing Clerk account is linked, not recreated", () => {
  const plan = buildProvisioningPlan({
    authUsers: [u("a1", "jane@example.com")],
    profilesById: new Map([["a1", { role: "admin" }]]),
    mappings: [],
    clerkUsersByEmail: new Map([["jane@example.com", { id: "user_existing" }]]),
  })
  assert.equal(plan.toCreate.length, 0)
  assert.deepEqual(plan.toLink, [
    {
      user: u("a1", "jane@example.com"),
      email: "jane@example.com",
      role: "operator",
      clerkUserId: "user_existing",
    },
  ])
})

test("users without an email are surfaced separately", () => {
  const plan = buildProvisioningPlan({
    authUsers: [u("a1", null), u("b1", "bob@example.com")],
    profilesById: new Map(),
    mappings: [],
    clerkUsersByEmail: new Map(),
  })
  assert.deepEqual(
    plan.noEmail.map((x) => x.id),
    ["a1"]
  )
  assert.deepEqual(
    plan.toCreate.map((x) => x.user.id),
    ["b1"]
  )
})

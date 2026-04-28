const {onCall, onRequest, HttpsError} = require("firebase-functions/v2/https");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const {logger} = require("firebase-functions");
const admin = require("firebase-admin");
const crypto = require("crypto");

admin.initializeApp();
const db = admin.firestore();

const SUPER_ADMIN_EMAILS = new Set([
  "nelsonjembe99@gmail.com",
]);

function sha256(v) {
  return crypto.createHash("sha256").update(v).digest("hex");
}

function hashPassword(raw) {
  const pwd = String(raw || "");
  const salt = crypto.randomBytes(16).toString("hex");
  const hash = sha256(`${salt}:${pwd}`);
  return `s2$${salt}$${hash}`;
}

function verifyPassword(raw, storedHash) {
  const pwd = String(raw || "");
  const hash = String(storedHash || "");
  if (!hash) return false;

  if (hash.startsWith("s2$")) {
    const parts = hash.split("$");
    if (parts.length !== 3) return false;
    const salt = parts[1];
    const expected = parts[2];
    const actual = sha256(`${salt}:${pwd}`);
    return crypto.timingSafeEqual(Buffer.from(actual), Buffer.from(expected));
  }

  // Legacy fallback
  return sha256(pwd) === hash;
}

function normalizeStopName(v) {
  return String(v || "").trim();
}

function stopKey(v) {
  return normalizeStopName(v).toLowerCase().replace(/\s+/g, "_");
}

function buildSegments(stopNames) {
  const out = [];
  for (let i = 0; i < stopNames.length - 1; i++) {
    for (let j = i + 1; j < stopNames.length; j++) {
      out.push({
        from: stopNames[i],
        to: stopNames[j],
        fromIndex: i,
        toIndex: j,
      });
    }
  }
  return out;
}

function normalizeRfidUid(v) {
  return String(v || "").trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
}

async function createUserNotification({
  userId,
  type,
  title,
  body,
  data = {},
}) {
  const uid = String(userId || "").trim();
  if (!uid) return;
  try {
    const now = admin.firestore.Timestamp.now();
    await db.collection("user_notifications").add({
      userId: uid,
      type: String(type || "system"),
      title: String(title || "Msafiri update"),
      body: String(body || ""),
      data,
      read: false,
      createdAt: now,
      updatedAt: now,
    });
  } catch (e) {
    logger.warn("createUserNotification failed", {
      userId: uid,
      type: String(type || "system"),
      error: String(e),
    });
  }
}

function toMessageData(raw) {
  const out = {};
  if (!raw || typeof raw !== "object") return out;
  for (const [k, v] of Object.entries(raw)) {
    if (!k) continue;
    if (v === null || v === undefined) continue;
    out[String(k)] = typeof v === "string" ? v : JSON.stringify(v);
  }
  return out;
}

exports.pushOnUserNotificationCreated = onDocumentCreated(
    {
      region: "us-central1",
      document: "user_notifications/{notificationId}",
    },
    async (event) => {
      const snap = event.data;
      if (!snap) return;
      const notificationId = String(event.params?.notificationId || snap.id || "");
      const payload = snap.data() || {};
      const userId = String(payload.userId || "").trim();
      if (!userId) return;

      try {
        const userSnap = await db.collection("traffic_users").doc(userId).get();
        if (!userSnap.exists) return;
        const user = userSnap.data() || {};
        const tokens = Array.isArray(user.fcmTokens) ?
          user.fcmTokens.map((t) => String(t || "").trim()).filter((t) => t.length > 0) :
          [];
        if (!tokens.length) return;

        const title = String(payload.title || "Msafiri");
        const body = String(payload.body || "");
        const data = toMessageData({
          ...(payload.data || {}),
          notificationId,
          type: String(payload.type || "generic"),
          title,
          body,
          userId,
        });

        const res = await admin.messaging().sendEachForMulticast({
          tokens,
          notification: {title, body},
          data,
          android: {
            notification: {
              channelId: "msafiri_alerts",
              sound: "default",
            },
            priority: "high",
          },
        });

        const invalid = [];
        for (let i = 0; i < res.responses.length; i++) {
          const r = res.responses[i];
          if (r.success) continue;
          const code = String(r.error?.code || "");
          if (code.includes("registration-token-not-registered") ||
            code.includes("invalid-registration-token")) {
            invalid.push(tokens[i]);
          }
        }

        await snap.ref.set({
          push: {
            attemptedAt: admin.firestore.Timestamp.now(),
            successCount: res.successCount,
            failureCount: res.failureCount,
          },
          updatedAt: admin.firestore.Timestamp.now(),
        }, {merge: true});

        if (invalid.length) {
          await db.collection("traffic_users").doc(userId).set({
            fcmTokens: admin.firestore.FieldValue.arrayRemove(...invalid),
            fcmTokenUpdatedAt: admin.firestore.Timestamp.now(),
          }, {merge: true});
        }
      } catch (e) {
        logger.warn("pushOnUserNotificationCreated failed", {
          userId,
          notificationId,
          error: String(e),
        });
      }
    },
);

async function resolveAuth(request) {
  const authUid = String(request.auth?.uid || "").trim();
  if (authUid) {
    return {
      uid: authUid,
      email: String(request.auth?.token?.email || "").toLowerCase(),
    };
  }

  const idToken = String(request.data?.idToken || "").trim();
  if (!idToken) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  try {
    const decoded = await admin.auth().verifyIdToken(idToken);
    return {
      uid: String(decoded.uid || "").trim(),
      email: String(decoded.email || "").toLowerCase(),
    };
  } catch (e) {
    logger.warn("resolveAuth verifyIdToken failed", {error: String(e)});
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
}

async function requireAuth(request) {
  const caller = await resolveAuth(request);
  if (!caller.uid) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  return caller;
}

async function isSuperAdmin(caller) {
  if (SUPER_ADMIN_EMAILS.has(caller.email)) return true;
  const profile = await db.collection("traffic_users").doc(caller.uid).get();
  if (!profile.exists) return false;
  const role = String(profile.data()?.role || "").toLowerCase();
  return role === "super_admin";
}

async function requireSuperAdmin(request) {
  const caller = await requireAuth(request);
  const allowed = await isSuperAdmin(caller);
  if (!allowed) {
    throw new HttpsError("permission-denied", "Super admin only.");
  }
  return caller;
}

async function requireAgencyAdmin(caller, requiredAgencyId = null) {
  const memberSnap = await db.collection("agency_members").doc(caller.uid).get();
  if (!memberSnap.exists) {
    throw new HttpsError("permission-denied", "No agency membership found.");
  }
  const member = memberSnap.data() || {};
  const agencyId = String(member.agencyId || "").trim();
  const role = String(member.role || "").toLowerCase();
  const active = member.active === true;
  if (!active || role !== "agency_admin" || !agencyId) {
    throw new HttpsError("permission-denied", "Agency admin access required.");
  }
  if (requiredAgencyId && agencyId !== requiredAgencyId) {
    throw new HttpsError("permission-denied", "Cannot access another agency.");
  }
  return {agencyId, role};
}

async function requireAgencyAdminOrSuperAdmin(caller, requiredAgencyId = null) {
  if (await isSuperAdmin(caller)) {
    return {agencyId: requiredAgencyId || "", role: "super_admin"};
  }
  return requireAgencyAdmin(caller, requiredAgencyId);
}

function parseJsonBody(req) {
  if (!req || !req.body) return {};
  if (typeof req.body === "string") {
    try {
      return JSON.parse(req.body);
    } catch (e) {
      return {};
    }
  }
  return req.body;
}

function isSeatAvailableAgainstLock(
  lock,
  requestDirectionId,
  requestOriginStopIndex,
  requestDestinationStopIndex,
) {
  const lockDirectionId = String(lock.directionId || "");
  const lockOriginStopIndex = Number(lock.originStopIndex || -1);
  const lockDestinationStopIndex = Number(lock.destinationStopIndex || -1);

  if (!lockDirectionId) return false;
  if (lockDirectionId !== requestDirectionId) return false;
  if (!Number.isInteger(lockOriginStopIndex) || !Number.isInteger(lockDestinationStopIndex)) {
    return false;
  }

  const overlaps = requestOriginStopIndex < lockDestinationStopIndex &&
    lockOriginStopIndex < requestDestinationStopIndex;
  return !overlaps;
}

exports.healthCheck = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireAuth(request);
  logger.info("healthCheck", {uid: caller.uid, email: caller.email});
  return {
    ok: true,
    module: "traffic_v2_baseline",
    region: "us-central1",
    ts: Date.now(),
  };
});

exports.upsertTrafficProfile = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireAuth(request);
  const now = admin.firestore.Timestamp.now();
  const displayName = String(request.data?.displayName || "").trim();
  const phone = String(request.data?.phone || "").trim();

  await db.collection("traffic_users").doc(caller.uid).set({
    uid: caller.uid,
    email: caller.email,
    displayName,
    phone,
    role: "rider",
    status: "active",
    agencyId: null,
    updatedAt: now,
    createdAt: now,
  }, {merge: true});

  logger.info("upsertTrafficProfile", {uid: caller.uid});
  return {ok: true, uid: caller.uid};
});

exports.submitAgencyApplicationV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireAuth(request);
  const data = request.data || {};

  const agencyName = String(data.agencyName || "").trim();
  const phone = String(data.phone || "").trim();
  const fleetSize = Number(data.fleetSize || 0);
  const agencyPassword = String(data.agencyPassword || "").trim();

  if (!agencyName || !phone || !Number.isFinite(fleetSize) || fleetSize <= 0) {
    throw new HttpsError("invalid-argument", "Invalid application payload.");
  }
  if (agencyPassword.length < 4) {
    throw new HttpsError("invalid-argument", "Agency password must be at least 4 characters.");
  }

  const existing = await db.collection("agency_applications")
    .where("ownerUid", "==", caller.uid)
    .where("status", "in", ["pending", "under_review"])
    .limit(1)
    .get();
  if (!existing.empty) {
    throw new HttpsError("already-exists", "You already have a pending application.");
  }

  const now = admin.firestore.Timestamp.now();
  const ref = await db.collection("agency_applications").add({
    ownerUid: caller.uid,
    ownerEmail: caller.email,
    agencyName,
    agencyNameLower: agencyName.toLowerCase(),
    phone,
    fleetSize,
    requestedPasswordHash: hashPassword(agencyPassword),
    status: "pending",
    submittedAt: now,
    updatedAt: now,
    reviewedAt: null,
    reviewedBy: null,
    rejectReason: null,
    provisionedAgencyId: null,
  });

  db.collection("mail").add({
    to: ["nelsonjembe99@gmail.com"],
    message: {
      subject: `Agency application: ${agencyName}`,
      text: [
        `Application ID: ${ref.id}`,
        `Agency: ${agencyName}`,
        `Owner UID: ${caller.uid}`,
        `Owner Email: ${caller.email}`,
        `Phone: ${phone}`,
        `Fleet: ${fleetSize}`,
      ].join("\n"),
    },
  }).catch((e) => logger.warn("mail enqueue failed", {error: String(e)}));

  logger.info("submitAgencyApplicationV2", {uid: caller.uid, applicationId: ref.id});
  return {ok: true, applicationId: ref.id, status: "pending"};
});

exports.reviewAgencyApplicationV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);
  const applicationId = String(request.data?.applicationId || "").trim();
  const decision = String(request.data?.decision || "").trim().toLowerCase();
  const reason = String(request.data?.reason || "").trim();
  const customAgencyCode = String(request.data?.agencyCode || "").trim().toUpperCase();

  if (!applicationId || !["approve", "reject"].includes(decision)) {
    throw new HttpsError("invalid-argument", "applicationId and valid decision are required.");
  }

  const now = admin.firestore.Timestamp.now();
  const appRef = db.collection("agency_applications").doc(applicationId);

  const result = await db.runTransaction(async (tx) => {
    const appSnap = await tx.get(appRef);
    if (!appSnap.exists) throw new HttpsError("not-found", "Application not found.");

    const app = appSnap.data() || {};
    const status = String(app.status || "").toLowerCase();
    if (status !== "pending" && status !== "under_review") {
      throw new HttpsError("failed-precondition", "Application already handled.");
    }

    if (decision === "reject") {
      tx.update(appRef, {
        status: "rejected",
        rejectReason: reason || "Not approved at this time.",
        reviewedAt: now,
        reviewedBy: caller.uid,
        updatedAt: now,
      });
      return {status: "rejected"};
    }

    const ownerUid = String(app.ownerUid || "").trim();
    const agencyName = String(app.agencyName || "").trim();
    const phone = String(app.phone || "").trim();
    const pwdHash = String(app.requestedPasswordHash || "").trim();
    if (!ownerUid || !agencyName || !pwdHash) {
      throw new HttpsError("failed-precondition", "Application data is incomplete.");
    }

    const agencyId = String(request.data?.agencyId || "").trim() || `agency_${applicationId}`;
    const agencyRef = db.collection("agencies").doc(agencyId);
    const memberRef = db.collection("agency_members").doc(ownerUid);
    const secretRef = db.collection("agency_secrets").doc(agencyId);
    const trafficUserRef = db.collection("traffic_users").doc(ownerUid);

    tx.set(agencyRef, {
      name: agencyName,
      nameLower: agencyName.toLowerCase(),
      code: customAgencyCode,
      active: true,
      ownerUid,
      adminPhone: phone,
      adminName: String(app.ownerEmail || "Agency Admin"),
      approvedFromApplicationId: applicationId,
      createdAt: now,
      updatedAt: now,
    }, {merge: true});

    tx.set(memberRef, {
      agencyId,
      email: String(app.ownerEmail || "").trim().toLowerCase(),
      role: "agency_admin",
      active: true,
      source: "application_approval_v2",
      createdAt: now,
      updatedAt: now,
    }, {merge: true});

    tx.set(secretRef, {
      passwordHash: pwdHash,
      updatedAt: now,
      updatedBy: ownerUid,
    }, {merge: true});

    tx.set(trafficUserRef, {
      agencyId,
      role: "agency_admin",
      status: "active",
      updatedAt: now,
    }, {merge: true});

    tx.update(appRef, {
      status: "approved",
      reviewedAt: now,
      reviewedBy: caller.uid,
      updatedAt: now,
      rejectReason: null,
      provisionedAgencyId: agencyId,
    });

    return {status: "approved", agencyId};
  });

  logger.info("reviewAgencyApplicationV2", {
    reviewer: caller.uid,
    applicationId,
    decision,
    result,
  });
  return {ok: true, applicationId, ...result};
});

exports.openAgencyByPasswordV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireAuth(request);
  const agencyId = String(request.data?.agencyId || "").trim();
  const password = String(request.data?.password || "").trim();

  if (!agencyId || !password) {
    throw new HttpsError("invalid-argument", "agencyId and password are required.");
  }

  const memberSnap = await db.collection("agency_members").doc(caller.uid).get();
  if (!memberSnap.exists) {
    throw new HttpsError("permission-denied", "No agency membership found.");
  }
  const member = memberSnap.data() || {};
  if (member.active !== true || String(member.agencyId || "") !== agencyId) {
    throw new HttpsError("permission-denied", "You do not belong to this agency.");
  }

  const [agencySnap, secretSnap] = await Promise.all([
    db.collection("agencies").doc(agencyId).get(),
    db.collection("agency_secrets").doc(agencyId).get(),
  ]);

  if (!agencySnap.exists || agencySnap.data()?.active !== true) {
    throw new HttpsError("failed-precondition", "Agency is not active.");
  }
  if (!secretSnap.exists) {
    throw new HttpsError("failed-precondition", "Agency password is not set yet.");
  }

  const hash = String(secretSnap.data()?.passwordHash || "");
  if (!verifyPassword(password, hash)) {
    throw new HttpsError("permission-denied", "Invalid agency password.");
  }

  return {
    ok: true,
    agencyId,
    role: String(member.role || ""),
  };
});

/**
 * Agency admin adds/updates an agency member role.
 * Super admin role is intentionally blocked here.
 */
exports.assignAgencyMemberRoleV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireAuth(request);
  const agencyId = String(request.data?.agencyId || "").trim();
  const memberEmailInput = String(request.data?.memberEmail || "").trim().toLowerCase();
  const memberUidInput = String(request.data?.memberUid || "").trim();
  const role = String(request.data?.role || "").trim().toLowerCase();

  if (!agencyId || (!memberEmailInput && !memberUidInput) || !role) {
    throw new HttpsError(
        "invalid-argument",
        "agencyId, role, and either memberEmail or memberUid are required.",
    );
  }
  if (role === "super_admin") {
    throw new HttpsError("permission-denied", "Agency admins cannot assign super_admin role.");
  }

  const allowedRoles = new Set([
    "agency_admin",
    "agency_staff",
    "dispatcher",
    "finance",
    "viewer",
  ]);
  if (!allowedRoles.has(role)) {
    throw new HttpsError("invalid-argument", "Invalid agency role.");
  }

  const agencyAccess = await requireAgencyAdmin(caller, agencyId);
  if (agencyAccess.agencyId !== agencyId) {
    throw new HttpsError("permission-denied", "Cannot assign member to another agency.");
  }

  let userRecord;
  try {
    userRecord = memberUidInput ?
      await admin.auth().getUser(memberUidInput) :
      await admin.auth().getUserByEmail(memberEmailInput);
  } catch (e) {
    throw new HttpsError("not-found", "No user found for the provided identity.");
  }
  const memberUid = String(userRecord.uid || "").trim();
  const memberEmail = String(userRecord.email || memberEmailInput || "").trim().toLowerCase();
  if (!memberUid) {
    throw new HttpsError("failed-precondition", "Resolved user has no UID.");
  }

  const now = admin.firestore.Timestamp.now();
  const memberRef = db.collection("agency_members").doc(memberUid);
  const trafficUserRef = db.collection("traffic_users").doc(memberUid);

  await db.runTransaction(async (tx) => {
    const existingMember = await tx.get(memberRef);
    const existingAgencyId = String(existingMember.data()?.agencyId || "").trim();
    if (existingMember.exists && existingAgencyId && existingAgencyId !== agencyId) {
      throw new HttpsError(
          "failed-precondition",
          "User already belongs to another agency. Remove them first.",
      );
    }

    tx.set(memberRef, {
      agencyId,
      email: memberEmail,
      role,
      active: true,
      updatedAt: now,
      updatedBy: caller.uid,
      createdAt: existingMember.exists ? (existingMember.data()?.createdAt || now) : now,
      createdBy: existingMember.exists ? (existingMember.data()?.createdBy || caller.uid) : caller.uid,
    }, {merge: true});

    tx.set(trafficUserRef, {
      uid: memberUid,
      email: memberEmail,
      agencyId,
      role,
      status: "active",
      updatedAt: now,
      createdAt: now,
    }, {merge: true});
  });

  logger.info("assignAgencyMemberRoleV2", {
    callerUid: caller.uid,
    agencyId,
    memberUid,
    memberEmail,
    role,
  });
  return {ok: true, agencyId, memberUid, memberEmail, role};
});

/**
 * Super admin can set any global role on traffic_users, including super_admin.
 */
exports.setUserGlobalRoleV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);
  const memberEmailInput = String(request.data?.memberEmail || "").trim().toLowerCase();
  const memberUidInput = String(request.data?.memberUid || "").trim();
  const role = String(request.data?.role || "").trim().toLowerCase();

  if ((!memberEmailInput && !memberUidInput) || !role) {
    throw new HttpsError(
        "invalid-argument",
        "role and either memberEmail or memberUid are required.",
    );
  }

  const allowedRoles = new Set([
    "rider",
    "agency_admin",
    "agency_staff",
    "dispatcher",
    "finance",
    "viewer",
    "super_admin",
  ]);
  if (!allowedRoles.has(role)) {
    throw new HttpsError("invalid-argument", "Invalid role.");
  }

  let userRecord;
  try {
    userRecord = memberUidInput ?
      await admin.auth().getUser(memberUidInput) :
      await admin.auth().getUserByEmail(memberEmailInput);
  } catch (e) {
    throw new HttpsError("not-found", "No user found for the provided identity.");
  }
  const uid = String(userRecord.uid || "").trim();
  const memberEmail = String(userRecord.email || memberEmailInput || "").trim().toLowerCase();
  if (!uid) throw new HttpsError("failed-precondition", "Resolved user has no UID.");

  const now = admin.firestore.Timestamp.now();
  await db.collection("traffic_users").doc(uid).set({
    uid,
    email: memberEmail,
    role,
    status: "active",
    updatedAt: now,
    updatedBy: caller.uid,
    createdAt: now,
  }, {merge: true});

  logger.info("setUserGlobalRoleV2", {
    callerUid: caller.uid,
    uid,
    memberEmail,
    role,
  });
  return {ok: true, uid, memberEmail, role};
});

/**
 * Super admin defines a full corridor as two directions:
 * forward (given stops order) and reverse (stops reversed).
 */
exports.createDirectionPairV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);
  const corridorName = String(request.data?.corridorName || "").trim();
  const stopsRaw = Array.isArray(request.data?.stops) ? request.data.stops : [];
  const stops = stopsRaw.map((s) => normalizeStopName(s)).filter((s) => s.length > 0);
  const defaultFareRwf = Number(request.data?.defaultFareRwf || 0);

  if (!corridorName || stops.length < 2) {
    throw new HttpsError("invalid-argument", "corridorName and at least 2 stops are required.");
  }

  const unique = new Set(stops.map((s) => stopKey(s)));
  if (unique.size !== stops.length) {
    throw new HttpsError("invalid-argument", "Stop names must be unique in a corridor.");
  }

  const now = admin.firestore.Timestamp.now();
  const pairId = db.collection("route_directions").doc().id;

  const forwardStops = stops;
  const reverseStops = [...stops].reverse();
  const forwardRef = db.collection("route_directions").doc();
  const reverseRef = db.collection("route_directions").doc();

  const forwardDoc = {
    pairId,
    corridorName,
    directionLabel: "forward",
    stopNames: forwardStops,
    stopKeys: forwardStops.map((s) => stopKey(s)),
    segments: buildSegments(forwardStops),
    defaultFareRwf: Number.isFinite(defaultFareRwf) ? defaultFareRwf : 0,
    faresBySegment: {},
    active: true,
    createdBy: caller.uid,
    createdAt: now,
    updatedAt: now,
    reverseDirectionId: reverseRef.id,
  };

  const reverseDoc = {
    pairId,
    corridorName,
    directionLabel: "reverse",
    stopNames: reverseStops,
    stopKeys: reverseStops.map((s) => stopKey(s)),
    segments: buildSegments(reverseStops),
    defaultFareRwf: Number.isFinite(defaultFareRwf) ? defaultFareRwf : 0,
    faresBySegment: {},
    active: true,
    createdBy: caller.uid,
    createdAt: now,
    updatedAt: now,
    reverseDirectionId: forwardRef.id,
  };

  const batch = db.batch();
  batch.set(forwardRef, forwardDoc);
  batch.set(reverseRef, reverseDoc);
  await batch.commit();

  logger.info("createDirectionPairV2", {
    by: caller.uid,
    pairId,
    forwardDirectionId: forwardRef.id,
    reverseDirectionId: reverseRef.id,
  });

  return {
    ok: true,
    pairId,
    forwardDirectionId: forwardRef.id,
    reverseDirectionId: reverseRef.id,
  };
});

exports.updateDirectionV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);
  const directionId = String(request.data?.directionId || "").trim();
  const corridorNameInput = String(request.data?.corridorName || "").trim();
  const stopsInputRaw = Array.isArray(request.data?.stops) ? request.data.stops : null;
  const defaultFareInput = request.data?.defaultFareRwf;

  if (!directionId) {
    throw new HttpsError("invalid-argument", "directionId is required.");
  }

  const directionRef = db.collection("route_directions").doc(directionId);
  const directionSnap = await directionRef.get();
  if (!directionSnap.exists) {
    throw new HttpsError("not-found", "Direction not found.");
  }
  const direction = directionSnap.data() || {};
  const reverseDirectionId = String(direction.reverseDirectionId || "").trim();
  if (!reverseDirectionId) {
    throw new HttpsError("failed-precondition", "Direction has no reverse link.");
  }

  let stops = Array.isArray(direction.stopNames) ? direction.stopNames.map((s) => normalizeStopName(s)) : [];
  if (stopsInputRaw) {
    stops = stopsInputRaw.map((s) => normalizeStopName(s)).filter((s) => s.length > 0);
  }
  if (stops.length < 2) {
    throw new HttpsError("invalid-argument", "At least 2 stops are required.");
  }
  const uniqueStops = new Set(stops.map((s) => stopKey(s)));
  if (uniqueStops.size !== stops.length) {
    throw new HttpsError("invalid-argument", "Stop names must be unique.");
  }

  const now = admin.firestore.Timestamp.now();
  const corridorName = corridorNameInput || String(direction.corridorName || "");
  const defaultFareRwf = Number.isFinite(Number(defaultFareInput)) ?
    Number(defaultFareInput) :
    Number(direction.defaultFareRwf || 0);

  const forwardStops = String(direction.directionLabel || "").toLowerCase() === "reverse" ?
    [...stops].reverse() :
    stops;
  const reverseStops = [...forwardStops].reverse();
  const reverseRef = db.collection("route_directions").doc(reverseDirectionId);

  await db.runTransaction(async (tx) => {
    const reverseSnap = await tx.get(reverseRef);
    if (!reverseSnap.exists) {
      throw new HttpsError("not-found", "Reverse direction not found.");
    }
    const reverse = reverseSnap.data() || {};

    tx.set(directionRef, {
      corridorName,
      stopNames: String(direction.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops,
      stopKeys: (String(direction.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops)
        .map((s) => stopKey(s)),
      segments: buildSegments(String(direction.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops),
      defaultFareRwf: Math.trunc(defaultFareRwf),
      faresBySegment: direction.faresBySegment || {},
      updatedAt: now,
      updatedBy: caller.uid,
    }, {merge: true});

    tx.set(reverseRef, {
      corridorName,
      stopNames: String(reverse.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops,
      stopKeys: (String(reverse.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops)
        .map((s) => stopKey(s)),
      segments: buildSegments(String(reverse.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops),
      defaultFareRwf: Math.trunc(defaultFareRwf),
      faresBySegment: reverse.faresBySegment || {},
      updatedAt: now,
      updatedBy: caller.uid,
    }, {merge: true});
  });

  return {
    ok: true,
    directionId,
    reverseDirectionId,
    corridorName,
    stopCount: stops.length,
    defaultFareRwf: Math.trunc(defaultFareRwf),
  };
});

async function setDirectionSegmentFareInternal({
  directionId,
  fromStopIndex,
  toStopIndex,
  fareRwf,
  callerUid,
}) {
  if (!directionId ||
      !Number.isInteger(fromStopIndex) ||
      !Number.isInteger(toStopIndex) ||
      !Number.isFinite(fareRwf) ||
      fareRwf < 0) {
    throw new HttpsError("invalid-argument", "Invalid fare payload.");
  }
  if (toStopIndex <= fromStopIndex) {
    throw new HttpsError("invalid-argument", "Destination stop must be after origin stop.");
  }

  const directionRef = db.collection("route_directions").doc(directionId);
  const directionSnap = await directionRef.get();
  if (!directionSnap.exists) {
    throw new HttpsError("not-found", "Direction not found.");
  }
  const direction = directionSnap.data() || {};
  const stops = Array.isArray(direction.stopNames) ? direction.stopNames : [];
  if (toStopIndex >= stops.length) {
    throw new HttpsError("invalid-argument", "Stop index out of bounds.");
  }

  const key = `${fromStopIndex}_${toStopIndex}`;
  const now = admin.firestore.Timestamp.now();
  const fromStopName = String(stops[fromStopIndex] || "");
  const toStopName = String(stops[toStopIndex] || "");
  const nextFares = {
    ...(direction.faresBySegment || {}),
    [key]: {
      fareRwf: Math.trunc(fareRwf),
      fromStopIndex,
      toStopIndex,
      fromStopName,
      toStopName,
      updatedAt: now,
    },
  };

  await directionRef.set({
    faresBySegment: nextFares,
    updatedAt: now,
    updatedBy: callerUid,
  }, {merge: true});

  return {
    key,
    fareRwf: Math.trunc(fareRwf),
    fromStopName,
    toStopName,
  };
}

exports.setDirectionSegmentFareV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);
  const directionId = String(request.data?.directionId || "").trim();
  const fromStopIndex = Number(request.data?.fromStopIndex);
  const toStopIndex = Number(request.data?.toStopIndex);
  const fareRwf = Number(request.data?.fareRwf);

  const result = await setDirectionSegmentFareInternal({
    directionId,
    fromStopIndex,
    toStopIndex,
    fareRwf,
    callerUid: caller.uid,
  });

  logger.info("setDirectionSegmentFareV2", {
    by: caller.uid,
    directionId,
    key: result.key,
    fareRwf: result.fareRwf,
  });

  return {ok: true, directionId, segmentKey: result.key, fareRwf: result.fareRwf};
});

exports.deleteDirectionSegmentFareV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);
  const directionId = String(request.data?.directionId || "").trim();
  const fromStopIndex = Number(request.data?.fromStopIndex);
  const toStopIndex = Number(request.data?.toStopIndex);

  if (!directionId ||
      !Number.isInteger(fromStopIndex) ||
      !Number.isInteger(toStopIndex) ||
      toStopIndex <= fromStopIndex) {
    throw new HttpsError("invalid-argument", "directionId/fromStopIndex/toStopIndex are required.");
  }

  const directionRef = db.collection("route_directions").doc(directionId);
  const snap = await directionRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "Direction not found.");

  const direction = snap.data() || {};
  const key = `${fromStopIndex}_${toStopIndex}`;
  const fares = {...(direction.faresBySegment || {})};
  delete fares[key];
  const now = admin.firestore.Timestamp.now();

  await directionRef.set({
    faresBySegment: fares,
    updatedAt: now,
    updatedBy: caller.uid,
  }, {merge: true});

  return {ok: true, directionId, segmentKey: key};
});

exports.extendDirectionPairV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);
  const directionId = String(request.data?.directionId || "").trim();
  const newStopName = normalizeStopName(request.data?.newStopName);

  if (!directionId || !newStopName) {
    throw new HttpsError("invalid-argument", "directionId and newStopName are required.");
  }

  const directionRef = db.collection("route_directions").doc(directionId);
  const directionSnap = await directionRef.get();
  if (!directionSnap.exists) throw new HttpsError("not-found", "Direction not found.");
  const direction = directionSnap.data() || {};
  const reverseDirectionId = String(direction.reverseDirectionId || "").trim();
  if (!reverseDirectionId) throw new HttpsError("failed-precondition", "Direction has no reverse link.");

  const reverseRef = db.collection("route_directions").doc(reverseDirectionId);
  const reverseSnap = await reverseRef.get();
  if (!reverseSnap.exists) throw new HttpsError("not-found", "Reverse direction not found.");
  const reverse = reverseSnap.data() || {};

  const existingForward = String(direction.directionLabel || "").toLowerCase() === "reverse" ?
    (Array.isArray(reverse.stopNames) ? reverse.stopNames : []).map((s) => normalizeStopName(s)) :
    (Array.isArray(direction.stopNames) ? direction.stopNames : []).map((s) => normalizeStopName(s));

  if (existingForward.length < 2) {
    throw new HttpsError("failed-precondition", "Current corridor stops are invalid.");
  }
  if (existingForward.map((s) => stopKey(s)).includes(stopKey(newStopName))) {
    throw new HttpsError("already-exists", "Stop already exists in this corridor.");
  }

  const forwardStops = [...existingForward, newStopName];
  const reverseStops = [...forwardStops].reverse();
  const now = admin.firestore.Timestamp.now();

  await db.runTransaction(async (tx) => {
    tx.set(directionRef, {
      stopNames: String(direction.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops,
      stopKeys: (String(direction.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops)
        .map((s) => stopKey(s)),
      segments: buildSegments(String(direction.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops),
      // Segment indexes change after extension, reset fares to avoid stale mappings.
      faresBySegment: {},
      updatedAt: now,
      updatedBy: caller.uid,
    }, {merge: true});

    tx.set(reverseRef, {
      stopNames: String(reverse.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops,
      stopKeys: (String(reverse.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops)
        .map((s) => stopKey(s)),
      segments: buildSegments(String(reverse.directionLabel || "").toLowerCase() === "reverse" ? reverseStops : forwardStops),
      faresBySegment: {},
      updatedAt: now,
      updatedBy: caller.uid,
    }, {merge: true});
  });

  return {
    ok: true,
    directionId,
    reverseDirectionId,
    stopCount: forwardStops.length,
    faresReset: true,
  };
});

exports.deleteDirectionPairV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);
  const directionId = String(request.data?.directionId || "").trim();
  if (!directionId) {
    throw new HttpsError("invalid-argument", "directionId is required.");
  }

  const directionSnap = await db.collection("route_directions").doc(directionId).get();
  if (!directionSnap.exists) {
    throw new HttpsError("not-found", "Direction not found.");
  }
  const direction = directionSnap.data() || {};
  const pairId = String(direction.pairId || "").trim();

  const pairDocs = pairId ?
    await db.collection("route_directions").where("pairId", "==", pairId).limit(10).get() :
    await db.collection("route_directions").where(admin.firestore.FieldPath.documentId(), "==", directionId).limit(1).get();
  if (pairDocs.empty) {
    throw new HttpsError("not-found", "Direction pair not found.");
  }

  const now = admin.firestore.Timestamp.now();
  const directionIds = pairDocs.docs.map((d) => d.id);

  const batch = db.batch();
  for (const d of pairDocs.docs) {
    batch.set(d.ref, {
      active: false,
      deletedAt: now,
      deletedBy: caller.uid,
      updatedAt: now,
    }, {merge: true});
  }

  for (const did of directionIds) {
    const assignDocs = await db.collection("bus_direction_assignments")
      .where("directionId", "==", did)
      .where("active", "==", true)
      .limit(500)
      .get();
    for (const a of assignDocs.docs) {
      batch.set(a.ref, {
        active: false,
        updatedAt: now,
        updatedBy: caller.uid,
      }, {merge: true});
    }
  }

  await batch.commit();
  return {ok: true, pairId: pairId || null, directionIds};
});

exports.getFinanceOverviewV2 = onCall({region: "us-central1"}, async (request) => {
  await requireSuperAdmin(request);
  try {
    const byAgency = new Map();
    let totalCollectionRwf = 0;

    // Avoid composite-index dependency for now.
    const snap = await db.collection("card_transactions")
      .where("type", "==", "ride_payment")
      .limit(5000)
      .get();

    for (const d of snap.docs) {
      const m = d.data() || {};
      const agencyId = String(m.agencyId || "unknown");
      const raw = Number(m.deltaRwf || m.amountDeltaRwf || 0);
      const paid = Math.abs(Math.trunc(raw));
      if (!Number.isFinite(paid) || paid <= 0) continue;
      totalCollectionRwf += paid;
      byAgency.set(agencyId, (byAgency.get(agencyId) || 0) + paid);
    }

    const agencies = [...byAgency.entries()]
      .map(([agencyId, totalPaidRwf]) => {
        const commissionRwf = Math.round(totalPaidRwf * 0.05);
        return {
          agencyId,
          totalPaidRwf,
          commissionRwf,
          agencyNetRwf: totalPaidRwf - commissionRwf,
        };
      })
      .sort((a, b) => b.totalPaidRwf - a.totalPaidRwf);

    const totalCommissionRwf = agencies.reduce((p, a) => p + a.commissionRwf, 0);

    return {
      ok: true,
      generatedAtMs: Date.now(),
      agencies,
      totalCollectionRwf,
      totalCommissionRwf,
      totalAgencyNetRwf: totalCollectionRwf - totalCommissionRwf,
    };
  } catch (e) {
    logger.error("getFinanceOverviewV2 failed", {error: String(e)});
    throw new HttpsError("internal", `Finance overview failed: ${String(e)}`);
  }
});

/**
 * Agency admin assigns one direction to a bus in their own agency.
 */
exports.assignBusDirectionV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireAuth(request);
  const requestedAgencyId = String(request.data?.agencyId || "").trim();
  const agencyAccess = await requireAgencyAdmin(caller, requestedAgencyId || null);
  const busId = String(request.data?.busId || "").trim();
  const directionId = String(request.data?.directionId || "").trim();

  if (!busId || !directionId) {
    throw new HttpsError("invalid-argument", "busId and directionId are required.");
  }

  const [busSnap, directionSnap] = await Promise.all([
    db.collection("buses").doc(busId).get(),
    db.collection("route_directions").doc(directionId).get(),
  ]);

  if (!directionSnap.exists) {
    throw new HttpsError("not-found", "Direction not found.");
  }
  const d = directionSnap.data() || {};
  if (d.active === false) {
    throw new HttpsError("failed-precondition", "Direction is inactive.");
  }

  const busData = busSnap.exists ? (busSnap.data() || {}) : {};
  const agencyId = agencyAccess.agencyId;
  const agencySnap = await db.collection("agencies").doc(agencyId).get();
  const agencyName = String(agencySnap.data()?.name || busData.agencyName || "").trim();
  const now = admin.firestore.Timestamp.now();

  await db.collection("bus_direction_assignments").doc(busId).set({
    busId,
    directionId,
    pairId: String(d.pairId || ""),
    reverseDirectionId: String(d.reverseDirectionId || ""),
    corridorName: String(d.corridorName || ""),
    directionLabel: String(d.directionLabel || ""),
    stopNames: Array.isArray(d.stopNames) ? d.stopNames : [],
    agencyId,
    agencyName,
    active: true,
    currentStopIndex: 0,
    updatedAt: now,
    updatedBy: caller.uid,
    createdAt: now,
  }, {merge: true});

  await db.collection("buses").doc(busId).set({
    agencyId,
    agencyName,
    routeDirectionId: directionId,
    routePairId: String(d.pairId || ""),
    routeDirectionLabel: String(d.directionLabel || ""),
    routeDirectionStops: Array.isArray(d.stopNames) ? d.stopNames : [],
    updatedAt: now,
  }, {merge: true});

  logger.info("assignBusDirectionV2", {
    by: caller.uid,
    busId,
    directionId,
    agencyId,
  });
  return {ok: true, busId, directionId};
});

exports.setAgencyDirectionFareV2 = onCall({region: "us-central1"}, async (request) => {
  // Kept for backward compatibility with older app versions.
  // Behavior is now global and super-admin only.
  const caller = await requireSuperAdmin(request);
  const directionId = String(request.data?.directionId || "").trim();
  const fromStopIndex = Number(request.data?.fromStopIndex);
  const toStopIndex = Number(request.data?.toStopIndex);
  const fareRwf = Number(request.data?.fareRwf);
  const result = await setDirectionSegmentFareInternal({
    directionId,
    fromStopIndex,
    toStopIndex,
    fareRwf,
    callerUid: caller.uid,
  });
  return {
    ok: true,
    migratedToGlobal: true,
    directionId,
    segmentKey: result.key,
    fareRwf: result.fareRwf,
  };
});

exports.issueRfidCardToUserV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);
  const issuerAgencyId = String(request.data?.issuerAgencyId || "global").trim() || "global";

  const riderUidInput = String(request.data?.riderUid || "").trim();
  const riderEmailInput = String(request.data?.riderEmail || "").trim().toLowerCase();
  const rfidUid = normalizeRfidUid(request.data?.rfidUid);
  const initialBalanceRwf = Number(request.data?.initialBalanceRwf || 0);

  if (!rfidUid || (!riderUidInput && !riderEmailInput)) {
    throw new HttpsError("invalid-argument", "riderUid/riderEmail and rfidUid are required.");
  }
  if (!Number.isFinite(initialBalanceRwf) || initialBalanceRwf < 0) {
    throw new HttpsError("invalid-argument", "initialBalanceRwf must be >= 0.");
  }

  let riderUid = riderUidInput;
  let riderProfile = null;

  if (riderUid) {
    const profileSnap = await db.collection("traffic_users").doc(riderUid).get();
    if (!profileSnap.exists) {
      throw new HttpsError("not-found", "Rider profile not found.");
    }
    riderProfile = profileSnap.data() || {};
  } else {
    const q = await db.collection("traffic_users")
      .where("email", "==", riderEmailInput)
      .limit(2)
      .get();
    if (q.empty) throw new HttpsError("not-found", "Rider email not found.");
    if (q.docs.length > 1) {
      throw new HttpsError("failed-precondition", "Duplicate rider email profiles found.");
    }
    const d = q.docs[0];
    riderUid = d.id;
    riderProfile = d.data() || {};
  }

  if (!riderUid) throw new HttpsError("failed-precondition", "Could not resolve rider uid.");
  const riderEmail = String(riderProfile.email || riderEmailInput || "");
  const riderName = String(riderProfile.displayName || "");

  const now = admin.firestore.Timestamp.now();
  const rfidKey = rfidUid.toLowerCase();
  const cardId = `rfid_${rfidKey}`;
  const cardRef = db.collection("cards").doc(cardId);
  const registryRef = db.collection("card_registry").doc(rfidKey);
  const userRef = db.collection("traffic_users").doc(riderUid);
  const txRef = db.collection("card_transactions").doc();
  const eventRef = db.collection("admin_events").doc();
  const existingActiveForUser = await db.collection("cards")
    .where("userId", "==", riderUid)
    .where("active", "==", true)
    .limit(5)
    .get();

  for (const d of existingActiveForUser.docs) {
    if (d.id !== cardId) {
      throw new HttpsError(
        "already-exists",
        "Rider already has an active card. Use replaceLostRfidCardV2.",
      );
    }
  }

  await db.runTransaction(async (tx) => {
    const [cardSnap, registrySnap] = await Promise.all([
      tx.get(cardRef),
      tx.get(registryRef),
    ]);

    if (registrySnap.exists) {
      const reg = registrySnap.data() || {};
      const existingCardId = String(reg.cardId || "");
      if (existingCardId && existingCardId !== cardId) {
        throw new HttpsError("already-exists", "RFID is already linked to another card.");
      }
    }

    if (cardSnap.exists) {
      const c = cardSnap.data() || {};
      if (c.active === true && String(c.userId || "") !== riderUid) {
        throw new HttpsError("already-exists", "RFID card is already assigned.");
      }
    }

    tx.set(cardRef, {
      id: cardId,
      cardType: "rfid",
      rfidUid,
      rfidKey,
      issuerAgencyId,
      userId: riderUid,
      userEmail: riderEmail,
      userName: riderName,
      balanceRwf: Math.trunc(initialBalanceRwf),
      active: true,
      status: "active",
      assignedAt: now,
      assignedBy: caller.uid,
      updatedAt: now,
      createdAt: now,
    }, {merge: true});

    tx.set(registryRef, {
      rfidUid,
      rfidKey,
      cardId,
      agencyId: issuerAgencyId,
      userId: riderUid,
      active: true,
      updatedAt: now,
      createdAt: now,
    }, {merge: true});

    tx.set(userRef, {
      primaryCardId: cardId,
      updatedAt: now,
    }, {merge: true});

    tx.set(eventRef, {
      type: "card_issue",
      agencyId: issuerAgencyId,
      actorId: caller.uid,
      cardId,
      userId: riderUid,
      note: `RFID card issued (${rfidUid})`,
      createdAt: now,
      updatedAt: now,
    });

    if (initialBalanceRwf > 0) {
      tx.set(txRef, {
        type: "top_up",
        source: "card_issue",
        cardId,
        userId: riderUid,
        agencyId: issuerAgencyId,
        deltaRwf: Math.trunc(initialBalanceRwf),
        balanceAfter: Math.trunc(initialBalanceRwf),
        performedBy: caller.uid,
        createdAt: now,
        updatedAt: now,
      });
    }
  });

  logger.info("issueRfidCardToUserV2", {
    by: caller.uid,
    issuerAgencyId,
    riderUid,
    cardId,
    rfidUid,
  });

  await createUserNotification({
    userId: riderUid,
    type: "card_issued",
    title: "Card issued",
    body: `Your new Msafiri card (${cardId}) is active.`,
    data: {cardId, rfidUid, issuerAgencyId},
  });

  return {
    ok: true,
    issuerAgencyId,
    riderUid,
    cardId,
    rfidUid,
    initialBalanceRwf: Math.trunc(initialBalanceRwf),
  };
});

exports.topUpAgencyCardV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);

  const cardId = String(request.data?.cardId || "").trim();
  const amountRwf = Number(request.data?.amountRwf || 0);
  const note = String(request.data?.note || "").trim();

  if (!cardId || !Number.isFinite(amountRwf) || amountRwf <= 0) {
    throw new HttpsError("invalid-argument", "cardId and positive amountRwf are required.");
  }

  const now = admin.firestore.Timestamp.now();
  const cardRef = db.collection("cards").doc(cardId);
  const txRef = db.collection("card_transactions").doc();
  const eventRef = db.collection("admin_events").doc();

  const result = await db.runTransaction(async (tx) => {
    const cardSnap = await tx.get(cardRef);
    if (!cardSnap.exists) throw new HttpsError("not-found", "Card not found.");
    const card = cardSnap.data() || {};
    if (card.active !== true) {
      throw new HttpsError("failed-precondition", "Card is not active.");
    }
    const agencyId = String(card.issuerAgencyId || "global");

    const current = Number(card.balanceRwf || 0);
    const next = Math.trunc(current + amountRwf);

    tx.set(cardRef, {
      balanceRwf: next,
      updatedAt: now,
      updatedBy: caller.uid,
    }, {merge: true});

    tx.set(txRef, {
      type: "top_up",
      source: "agency_admin",
      cardId,
      userId: String(card.userId || ""),
      agencyId,
      deltaRwf: Math.trunc(amountRwf),
      balanceBefore: Math.trunc(current),
      balanceAfter: next,
      note,
      performedBy: caller.uid,
      createdAt: now,
      updatedAt: now,
    });

    tx.set(eventRef, {
      type: "card_top_up",
      agencyId,
      actorId: caller.uid,
      cardId,
      note: note || `Top up ${Math.trunc(amountRwf)} RWF`,
      createdAt: now,
      updatedAt: now,
    });

    return {balanceRwf: next, userId: String(card.userId || "")};
  });

  logger.info("topUpAgencyCardV2", {
    by: caller.uid,
    cardId,
    amountRwf: Math.trunc(amountRwf),
    balanceRwf: result.balanceRwf,
  });

  await createUserNotification({
    userId: result.userId,
    type: "top_up",
    title: "Top up received",
    body: `RWF ${Math.trunc(amountRwf)} added. New balance: RWF ${result.balanceRwf}.`,
    data: {cardId, amountRwf: Math.trunc(amountRwf), balanceRwf: result.balanceRwf},
  });

  return {
    ok: true,
    cardId,
    amountRwf: Math.trunc(amountRwf),
    balanceRwf: result.balanceRwf,
    userId: result.userId,
  };
});

exports.replaceLostRfidCardV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);

  const riderUidInput = String(request.data?.riderUid || "").trim();
  const riderEmailInput = String(request.data?.riderEmail || "").trim().toLowerCase();
  const newRfidUid = normalizeRfidUid(request.data?.newRfidUid);
  const oldCardIdInput = String(request.data?.oldCardId || "").trim();

  if ((!riderUidInput && !riderEmailInput) || !newRfidUid) {
    throw new HttpsError("invalid-argument", "riderUid/riderEmail and newRfidUid are required.");
  }

  let riderUid = riderUidInput;
  if (!riderUid) {
    const q = await db.collection("traffic_users").where("email", "==", riderEmailInput).limit(2).get();
    if (q.empty) throw new HttpsError("not-found", "Rider email not found.");
    if (q.docs.length > 1) throw new HttpsError("failed-precondition", "Duplicate rider email profiles found.");
    riderUid = q.docs[0].id;
  }

  const oldCardSnap = oldCardIdInput ?
    await db.collection("cards").doc(oldCardIdInput).get() :
    null;

  let oldCard = null;
  if (oldCardSnap && oldCardSnap.exists) {
    oldCard = {id: oldCardSnap.id, ...(oldCardSnap.data() || {})};
  } else {
    const q = await db.collection("cards")
      .where("userId", "==", riderUid)
      .where("active", "==", true)
      .limit(2)
      .get();
    if (q.empty) throw new HttpsError("not-found", "No active card found for rider.");
    if (q.docs.length > 1) {
      throw new HttpsError("failed-precondition", "Multiple active cards found. Provide oldCardId.");
    }
    oldCard = {id: q.docs[0].id, ...(q.docs[0].data() || {})};
  }

  if (!oldCard) throw new HttpsError("not-found", "Old card not found.");
  if (String(oldCard.userId || "") !== riderUid) {
    throw new HttpsError("permission-denied", "Old card does not belong to rider.");
  }
  const issuerAgencyId = String(oldCard.issuerAgencyId || "global");

  const newRfidKey = newRfidUid.toLowerCase();
  const newCardId = `rfid_${newRfidKey}`;
  const newCardRef = db.collection("cards").doc(newCardId);
  const newRegistryRef = db.collection("card_registry").doc(newRfidKey);
  const oldCardRef = db.collection("cards").doc(String(oldCard.id));
  const oldRfidKey = String(oldCard.rfidKey || "").trim();
  const oldRegistryRef = oldRfidKey ? db.collection("card_registry").doc(oldRfidKey) : null;
  const userRef = db.collection("traffic_users").doc(riderUid);
  const eventRef = db.collection("admin_events").doc();

  const now = admin.firestore.Timestamp.now();

  await db.runTransaction(async (tx) => {
    const [newCardSnap, newRegSnap] = await Promise.all([
      tx.get(newCardRef),
      tx.get(newRegistryRef),
    ]);

    if (newRegSnap.exists) {
      throw new HttpsError("already-exists", "New RFID is already linked.");
    }
    if (newCardSnap.exists && newCardSnap.data()?.active === true) {
      throw new HttpsError("already-exists", "New RFID card is already active.");
    }

    const oldBalance = Math.trunc(Number(oldCard.balanceRwf || 0));

    tx.set(oldCardRef, {
      active: false,
      status: "lost_replaced",
      replacedByCardId: newCardId,
      replacedAt: now,
      updatedAt: now,
      updatedBy: caller.uid,
    }, {merge: true});

    if (oldRegistryRef) {
      tx.set(oldRegistryRef, {
        active: false,
        replacedByCardId: newCardId,
        updatedAt: now,
      }, {merge: true});
    }

    tx.set(newCardRef, {
      id: newCardId,
      cardType: "rfid",
      rfidUid: newRfidUid,
      rfidKey: newRfidKey,
      issuerAgencyId,
      userId: riderUid,
      userEmail: String(oldCard.userEmail || ""),
      userName: String(oldCard.userName || ""),
      balanceRwf: oldBalance,
      active: true,
      status: "active",
      replacedFromCardId: String(oldCard.id),
      assignedAt: now,
      assignedBy: caller.uid,
      createdAt: now,
      updatedAt: now,
    }, {merge: true});

    tx.set(newRegistryRef, {
      rfidUid: newRfidUid,
      rfidKey: newRfidKey,
      cardId: newCardId,
      agencyId: issuerAgencyId,
      userId: riderUid,
      active: true,
      createdAt: now,
      updatedAt: now,
    }, {merge: true});

    tx.set(userRef, {
      primaryCardId: newCardId,
      updatedAt: now,
    }, {merge: true});

    tx.set(eventRef, {
      type: "card_replace",
      agencyId: issuerAgencyId,
      actorId: caller.uid,
      userId: riderUid,
      oldCardId: String(oldCard.id),
      newCardId,
      note: `Lost card replaced with new RFID (${newRfidUid})`,
      createdAt: now,
      updatedAt: now,
    });
  });

  logger.info("replaceLostRfidCardV2", {
    by: caller.uid,
    issuerAgencyId,
    riderUid,
    oldCardId: String(oldCard.id),
    newCardId,
  });

  await createUserNotification({
    userId: riderUid,
    type: "card_replaced",
    title: "Card replaced",
    body: `Your card was replaced. New card: ${newCardId}.`,
    data: {oldCardId: String(oldCard.id), newCardId, newRfidUid},
  });

  return {
    ok: true,
    agencyId: issuerAgencyId,
    riderUid,
    oldCardId: String(oldCard.id),
    newCardId,
    newRfidUid,
  };
});

async function bookSeatHandler(request) {
  const caller = await requireAuth(request);

  const busId = String(request.data?.busId || "").trim();
  const directionId = String(request.data?.directionId || request.data?.routeId || "").trim();
  const cardId = String(request.data?.cardId || "").trim();
  const seatNo = Number(request.data?.seatNo);
  const originStopIndex = Number(request.data?.originStopIndex);
  const destinationStopIndex = Number(request.data?.destinationStopIndex);
  const idempotencyKey = String(request.data?.idempotencyKey || "").trim();
  const bookingGroupId = String(request.data?.bookingGroupId || "").trim();

  if (!busId || !directionId || !cardId || !Number.isInteger(seatNo) || seatNo <= 0 ||
      !Number.isInteger(originStopIndex) || originStopIndex < 0 ||
      !Number.isInteger(destinationStopIndex) || destinationStopIndex <= originStopIndex ||
      !idempotencyKey) {
    throw new HttpsError("invalid-argument", "Invalid booking payload.");
  }

  const bookingId = `${caller.uid}_${idempotencyKey}`.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 120);
  const bookingRef = db.collection("bookings").doc(bookingId);
  const cardRef = db.collection("cards").doc(cardId);
  const lockRef = db.collection("seat_locks").doc(busId).collection("seats").doc(String(seatNo));

  const existingBooking = await bookingRef.get();
  if (existingBooking.exists) {
    return {ok: true, bookingId, idempotent: true};
  }

  const [assignmentSnap, directionSnap, cardSnap, lockSnap] = await Promise.all([
    db.collection("bus_direction_assignments").doc(busId).get(),
    db.collection("route_directions").doc(directionId).get(),
    cardRef.get(),
    lockRef.get(),
  ]);

  if (!assignmentSnap.exists) {
    throw new HttpsError("failed-precondition", "Bus has no direction assignment.");
  }
  const assignment = assignmentSnap.data() || {};
  if (assignment.active !== true || String(assignment.directionId || "") !== directionId) {
    throw new HttpsError("failed-precondition", "Bus is not assigned to selected direction.");
  }

  if (!directionSnap.exists) throw new HttpsError("not-found", "Direction not found.");
  const direction = directionSnap.data() || {};
  const stops = Array.isArray(direction.stopNames) ? direction.stopNames : [];
  if (destinationStopIndex >= stops.length) {
    throw new HttpsError("invalid-argument", "Stop index out of bounds.");
  }

  if (!cardSnap.exists) throw new HttpsError("not-found", "Card not found.");
  const card = cardSnap.data() || {};
  if (card.active !== true) throw new HttpsError("failed-precondition", "Card is not active.");
  if (String(card.userId || "") !== caller.uid) {
    throw new HttpsError("permission-denied", "Card does not belong to caller.");
  }

  const agencyId = String(assignment.agencyId || "").trim();
  const fareBySegment = direction.faresBySegment || {};
  const segmentKey = `${originStopIndex}_${destinationStopIndex}`;
  const segRaw = fareBySegment?.[segmentKey];
  const fareFromSegment = Number(
      typeof segRaw === "number" ? segRaw : (segRaw?.fareRwf || 0),
  );
  const fareRwf = Math.trunc(fareFromSegment);
  if (fareRwf <= 0) {
    throw new HttpsError(
        "failed-precondition",
        "Fare is not configured for this chunk yet. Ask super admin to set chunk fare.",
    );
  }

  if (lockSnap.exists) {
    const available = isSeatAvailableAgainstLock(
      lockSnap.data() || {},
      directionId,
      originStopIndex,
      destinationStopIndex,
    );
    if (!available) {
      throw new HttpsError("already-exists", "Seat already occupied on this segment.");
    }
  }

  const now = admin.firestore.Timestamp.now();
  const releaseAtMs = 0;

  await db.runTransaction(async (tx) => {
    const lockCheck = await tx.get(lockRef);
    if (lockCheck.exists) {
      const available = isSeatAvailableAgainstLock(
        lockCheck.data() || {},
        directionId,
        originStopIndex,
        destinationStopIndex,
      );
      if (!available) {
        throw new HttpsError("already-exists", "Seat already occupied on this segment.");
      }
    }

    const cardTxSnap = await tx.get(cardRef);
    if (!cardTxSnap.exists) {
      throw new HttpsError("not-found", "Card not found.");
    }
    const cardTx = cardTxSnap.data() || {};
    if (cardTx.active !== true) {
      throw new HttpsError("failed-precondition", "Card is not active.");
    }
    if (String(cardTx.userId || "") !== caller.uid) {
      throw new HttpsError("permission-denied", "Card does not belong to caller.");
    }

    const openBookingsSnap = await tx.get(
      db.collection("bookings")
        .where("cardId", "==", cardId)
        .where("status", "==", "booked")
        .limit(250),
    );
    let reservedRwf = 0;
    for (const d of openBookingsSnap.docs) {
      reservedRwf += Math.trunc(Number(d.data()?.fareRwf || 0));
    }

    const balanceRwf = Math.trunc(Number(cardTx.balanceRwf || 0));
    if (balanceRwf < reservedRwf + fareRwf) {
      throw new HttpsError(
          "failed-precondition",
          "Insufficient balance for this booking. Top up and retry.",
      );
    }

    tx.set(bookingRef, {
      id: bookingId,
      idempotencyKey,
      bookingGroupId: bookingGroupId || null,
      userId: caller.uid,
      bookingUserName: String(card.userName || ""),
      bookingUserEmail: String(card.userEmail || ""),
      busId,
      agencyId,
      directionId,
      routeId: directionId,
      routeLabel: `${String(direction.corridorName || "")} (${String(direction.directionLabel || "")})`,
      originStopIndex,
      destinationStopIndex,
      originStopName: String(stops[originStopIndex] || ""),
      destinationStopName: String(stops[destinationStopIndex] || ""),
      cardId,
      seatNo: Math.trunc(seatNo),
      fareRwf,
      status: "booked",
      seatReleased: false,
      releaseAtMs,
      createdAt: now,
      updatedAt: now,
    }, {merge: true});

    tx.set(lockRef, {
      bookingId,
      userId: caller.uid,
      cardId,
      busId,
      seatNo: Math.trunc(seatNo),
      directionId,
      originStopIndex,
      destinationStopIndex,
      releaseAtMs,
      status: "booked",
      createdAt: now,
      updatedAt: now,
    }, {merge: true});
  });

  logger.info("bookSeat", {
    uid: caller.uid,
    bookingId,
    busId,
    seatNo: Math.trunc(seatNo),
    directionId,
    originStopIndex,
    destinationStopIndex,
    releaseAtMs,
  });

  return {
    ok: true,
    bookingId,
    bookingGroupId: bookingGroupId || null,
    status: "booked",
    fareRwf,
    releaseAtMs,
  };
}

exports.cancelMyBookingSeatV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireAuth(request);
  const bookingId = String(request.data?.bookingId || "").trim();
  if (!bookingId) throw new HttpsError("invalid-argument", "bookingId is required.");

  const bookingRef = db.collection("bookings").doc(bookingId);
  const now = admin.firestore.Timestamp.now();

  const result = await db.runTransaction(async (tx) => {
    const bookingSnap = await tx.get(bookingRef);
    if (!bookingSnap.exists) throw new HttpsError("not-found", "Booking not found.");
    const booking = bookingSnap.data() || {};
    if (String(booking.userId || "") !== caller.uid) {
      throw new HttpsError("permission-denied", "You can only cancel your own bookings.");
    }
    const status = String(booking.status || "").toLowerCase();
    if (status === "paid") {
      throw new HttpsError("failed-precondition", "Paid booking cannot be cancelled here.");
    }
    if (status === "cancelled" || status === "released") {
      return {bookingId, alreadyCancelled: true};
    }
    if (status !== "booked") {
      throw new HttpsError("failed-precondition", `Cannot cancel booking in status: ${status}`);
    }

    const busId = String(booking.busId || "").trim();
    const seatNo = Math.trunc(Number(booking.seatNo || 0));
    const lockRef = db.collection("seat_locks").doc(busId).collection("seats").doc(String(seatNo));
    const lockSnap = await tx.get(lockRef);
    const lock = lockSnap.data() || {};
    if (lockSnap.exists && String(lock.bookingId || "") === bookingId) {
      tx.set(lockRef, {
        status: "released",
        releasedAt: now,
        updatedAt: now,
      }, {merge: true});
    }

    tx.set(bookingRef, {
      status: "cancelled",
      seatReleased: true,
      cancelledAt: now,
      updatedAt: now,
    }, {merge: true});

    return {bookingId, alreadyCancelled: false};
  });

  return {ok: true, ...result};
});

exports.cancelMyBookingGroupV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireAuth(request);
  const bookingGroupId = String(request.data?.bookingGroupId || "").trim();
  if (!bookingGroupId) {
    throw new HttpsError("invalid-argument", "bookingGroupId is required.");
  }

  const q = await db.collection("bookings")
    .where("userId", "==", caller.uid)
    .where("bookingGroupId", "==", bookingGroupId)
    .where("status", "==", "booked")
    .limit(100)
    .get();

  if (q.empty) {
    return {ok: true, bookingGroupId, cancelledCount: 0};
  }

  const now = admin.firestore.Timestamp.now();
  const batch = db.batch();
  let count = 0;
  for (const d of q.docs) {
    const b = d.data() || {};
    const busId = String(b.busId || "");
    const seatNo = Math.trunc(Number(b.seatNo || 0));
    const lockRef = db.collection("seat_locks").doc(busId).collection("seats").doc(String(seatNo));
    batch.set(lockRef, {
      status: "released",
      releasedAt: now,
      updatedAt: now,
    }, {merge: true});
    batch.set(d.ref, {
      status: "cancelled",
      seatReleased: true,
      cancelledAt: now,
      updatedAt: now,
    }, {merge: true});
    count++;
  }
  await batch.commit();

  return {ok: true, bookingGroupId, cancelledCount: count};
});

exports.bookSeat = onCall({region: "us-central1"}, async (request) => {
  return bookSeatHandler(request);
});

exports.bookSeatV1 = onCall({region: "us-central1"}, async (request) => {
  return bookSeatHandler(request);
});

async function payBookedTripsWithCard({
  busId,
  cardId,
  agencyId,
  actorId,
  seatNo = null,
  source = "tap_card",
}) {
  const cardRef = db.collection("cards").doc(cardId);
  const now = admin.firestore.Timestamp.now();

  const result = await db.runTransaction(async (tx) => {
    const cardSnap = await tx.get(cardRef);
    if (!cardSnap.exists) throw new HttpsError("not-found", "Card not found.");
    const card = cardSnap.data() || {};
    if (card.active !== true) throw new HttpsError("failed-precondition", "Card is not active.");

    let bookingDocs = [];
    if (Number.isInteger(seatNo) && seatNo > 0) {
      const q = await tx.get(
        db.collection("bookings")
          .where("busId", "==", busId)
          .where("cardId", "==", cardId)
          .where("seatNo", "==", Math.trunc(seatNo))
          .where("status", "==", "booked")
          .limit(10),
      );
      bookingDocs = q.docs;
    } else {
      const q = await tx.get(
        db.collection("bookings")
          .where("busId", "==", busId)
          .where("cardId", "==", cardId)
          .where("status", "==", "booked")
          .limit(25),
      );
      bookingDocs = q.docs;
    }

    if (!bookingDocs.length) {
      throw new HttpsError("not-found", "No booked trips found for this card on this bus.");
    }

    let totalFare = 0;
    for (const d of bookingDocs) {
      totalFare += Math.trunc(Number(d.data()?.fareRwf || 0));
    }
    if (totalFare <= 0) {
      throw new HttpsError("failed-precondition", "Booked trips have invalid fares.");
    }

    const balance = Math.trunc(Number(card.balanceRwf || 0));
    if (balance < totalFare) throw new HttpsError("failed-precondition", "Insufficient balance.");
    const nextBalance = balance - totalFare;

    tx.set(cardRef, {
      balanceRwf: nextBalance,
      updatedAt: now,
      updatedBy: actorId,
    }, {merge: true});

    const paidBookingIds = [];
    for (const bDoc of bookingDocs) {
      const booking = bDoc.data() || {};
      const fare = Math.trunc(Number(booking.fareRwf || 0));
      const bookingRef = db.collection("bookings").doc(bDoc.id);
      const lockRef = db.collection("seat_locks")
        .doc(String(booking.busId || busId))
        .collection("seats")
        .doc(String(booking.seatNo || ""));

      const txRef = db.collection("card_transactions").doc();
      const eventRef = db.collection("admin_events").doc();

      tx.set(bookingRef, {
        status: "paid",
        paidAt: now,
        paidBy: actorId,
        paymentCardId: cardId,
        paymentTxId: txRef.id,
        updatedAt: now,
      }, {merge: true});

      tx.set(lockRef, {
        bookingId: bDoc.id,
        userId: String(booking.userId || ""),
        cardId,
        busId: String(booking.busId || busId),
        seatNo: Math.trunc(Number(booking.seatNo || 0)),
        directionId: String(booking.directionId || booking.routeId || ""),
        routeId: String(booking.routeId || booking.directionId || ""),
        originStopIndex: Math.trunc(Number(booking.originStopIndex || -1)),
        destinationStopIndex: Math.trunc(Number(booking.destinationStopIndex || -1)),
        status: "paid",
        paidAt: now,
        updatedAt: now,
      }, {merge: true});

      tx.set(txRef, {
        type: "ride_payment",
        source,
        cardId,
        userId: String(booking.userId || ""),
        agencyId,
        bookingId: bDoc.id,
        busId: String(booking.busId || busId),
        seatNo: Math.trunc(Number(booking.seatNo || 0)),
        directionId: String(booking.directionId || booking.routeId || ""),
        originStopIndex: Math.trunc(Number(booking.originStopIndex || -1)),
        destinationStopIndex: Math.trunc(Number(booking.destinationStopIndex || -1)),
        originStopName: String(booking.originStopName || ""),
        destinationStopName: String(booking.destinationStopName || ""),
        deltaRwf: -fare,
        balanceBefore: balance,
        balanceAfter: nextBalance,
        performedBy: actorId,
        createdAt: now,
        updatedAt: now,
      });

      tx.set(eventRef, {
        type: "tap_payment",
        agencyId,
        actorId,
        cardId,
        bookingId: bDoc.id,
        note: `Tap payment successful for seat ${Math.trunc(Number(booking.seatNo || 0))} on ${busId}`,
        createdAt: now,
        updatedAt: now,
      });

      paidBookingIds.push(bDoc.id);
    }

    return {
      paidBookingIds,
      totalFareRwf: totalFare,
      balanceRwf: nextBalance,
      userId: String(card.userId || ""),
    };
  });

  logger.info("tapCardPayment", {
    by: actorId,
    agencyId,
    cardId,
    busId,
    seatNo: Number.isInteger(seatNo) ? Math.trunc(seatNo) : null,
    paidCount: result.paidBookingIds.length,
    totalFareRwf: result.totalFareRwf,
  });

  const userIdForNotify = String(result.userId || "");
  if (userIdForNotify && result.balanceRwf < 1000) {
    await createUserNotification({
      userId: userIdForNotify,
      type: "low_balance",
      title: "Low balance warning",
      body: `Your balance is below RWF 1000 (RWF ${result.balanceRwf}).`,
      data: {cardId, balanceRwf: result.balanceRwf},
    });
  }

  return result;
}

async function resolveCardFromInput({rfidUid, cardIdInput}) {
  let cardId = String(cardIdInput || "").trim();
  const normalized = normalizeRfidUid(rfidUid);
  if (cardId) return cardId;
  if (!normalized) throw new HttpsError("invalid-argument", "rfidUid/cardId is required.");
  const regSnap = await db.collection("card_registry").doc(normalized.toLowerCase()).get();
  if (!regSnap.exists) throw new HttpsError("not-found", "RFID not registered.");
  const reg = regSnap.data() || {};
  if (reg.active !== true) throw new HttpsError("failed-precondition", "RFID is inactive.");
  cardId = String(reg.cardId || "");
  if (!cardId) throw new HttpsError("failed-precondition", "RFID registry is invalid.");
  return cardId;
}

async function getCardOwnerUserId(cardId) {
  const safeCardId = String(cardId || "").trim();
  if (!safeCardId) return "";
  try {
    const cardSnap = await db.collection("cards").doc(safeCardId).get();
    if (!cardSnap.exists) return "";
    const card = cardSnap.data() || {};
    return String(card.userId || "").trim();
  } catch (e) {
    logger.warn("getCardOwnerUserId failed", {
      cardId: safeCardId,
      error: String(e),
    });
    return "";
  }
}

exports.tapCardV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireAuth(request);
  const busId = String(request.data?.busId || "").trim();
  const seatNoRaw = Number(request.data?.seatNo);
  const seatNo = Number.isInteger(seatNoRaw) && seatNoRaw > 0 ? Math.trunc(seatNoRaw) : null;
  const rfidUid = String(request.data?.rfidUid || "");
  const cardIdInput = String(request.data?.cardId || "");

  if (!busId || (!rfidUid.trim() && !cardIdInput.trim())) {
    throw new HttpsError("invalid-argument", "busId and rfidUid/cardId are required.");
  }

  const assignmentSnap = await db.collection("bus_direction_assignments").doc(busId).get();
  if (!assignmentSnap.exists) throw new HttpsError("failed-precondition", "Bus assignment missing.");
  const assignment = assignmentSnap.data() || {};
  const agencyId = String(assignment.agencyId || "").trim();
  await requireAgencyAdminOrSuperAdmin(caller, agencyId || null);

  let cardId = "";
  try {
    cardId = await resolveCardFromInput({rfidUid, cardIdInput});
    const result = await payBookedTripsWithCard({
      busId,
      cardId,
      agencyId,
      actorId: caller.uid,
      seatNo,
      source: "tap_card",
    });

    const tapMessage = `Tap successful: RWF ${result.totalFareRwf} paid on ${busId}. Balance: RWF ${result.balanceRwf}.`;
    const notifyUid = String(result.userId || "");
    if (notifyUid) {
      await createUserNotification({
        userId: notifyUid,
        type: "tap_result",
        title: "Tap successful",
        body: tapMessage,
        data: {
          success: true,
          busId,
          cardId,
          seatNo,
          paidBookingIds: result.paidBookingIds,
          totalFareRwf: result.totalFareRwf,
          balanceRwf: result.balanceRwf,
        },
      });
    }

    return {
      ok: true,
      cardId,
      busId,
      paidBookingIds: result.paidBookingIds,
      totalFareRwf: result.totalFareRwf,
      balanceRwf: result.balanceRwf,
      message: tapMessage,
    };
  } catch (e) {
    const code = e instanceof HttpsError ? e.code : "internal";
    const msg = String(e instanceof HttpsError ? e.message : (e?.message || e));
    const ownerUid = await getCardOwnerUserId(cardId);
    if (ownerUid) {
      await createUserNotification({
        userId: ownerUid,
        type: "tap_result",
        title: "Tap failed",
        body: msg,
        data: {
          success: false,
          busId,
          cardId,
          seatNo,
          errorCode: code,
        },
      });
    }
    throw e;
  }
});

exports.tapCardDeviceV2 = onRequest({region: "us-central1"}, async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") {
    res.status(204).send("");
    return;
  }
  if (req.method !== "POST") {
    res.status(405).json({ok: false, error: "method-not-allowed"});
    return;
  }

  try {
    const body = parseJsonBody(req);
    const data = body && body.data ? body.data : body;
    const busId = String(data?.busId || "").trim();
    const rfidUid = normalizeRfidUid(data?.rfidUid);
    const deviceSecret = String(data?.deviceSecret || "").trim();
    const seatNoRaw = Number(data?.seatNo);
    const seatNo = Number.isInteger(seatNoRaw) && seatNoRaw > 0 ? Math.trunc(seatNoRaw) : null;

    if (!busId || !rfidUid || !deviceSecret) {
      res.status(400).json({ok: false, error: "invalid-argument"});
      return;
    }

    const assignmentSnap = await db.collection("bus_direction_assignments").doc(busId).get();
    if (!assignmentSnap.exists) {
      res.status(412).json({ok: false, error: "bus-assignment-missing"});
      return;
    }
    const assignment = assignmentSnap.data() || {};
    const agencyId = String(assignment.agencyId || "").trim();

    const deviceSnap = await admin.database().ref(`devices/${busId}/deviceSecret`).get();
    const expectedSecret = String(deviceSnap.val() || "");
    if (!expectedSecret || expectedSecret !== deviceSecret) {
      res.status(403).json({ok: false, error: "invalid-device-secret"});
      return;
    }

    const cardId = await resolveCardFromInput({rfidUid, cardIdInput: ""});
    const result = await payBookedTripsWithCard({
      busId,
      cardId,
      agencyId,
      actorId: `device:${busId}`,
      seatNo,
      source: "tap_device",
    });

    const tapMessage = `Tap successful: RWF ${result.totalFareRwf} paid on ${busId}. Balance: RWF ${result.balanceRwf}.`;
    const notifyUid = String(result.userId || "");
    if (notifyUid) {
      await createUserNotification({
        userId: notifyUid,
        type: "tap_result",
        title: "Tap successful",
        body: tapMessage,
        data: {
          success: true,
          busId,
          cardId,
          seatNo,
          paidBookingIds: result.paidBookingIds,
          totalFareRwf: result.totalFareRwf,
          balanceRwf: result.balanceRwf,
        },
      });
    }

    res.status(200).json({
      ok: true,
      busId,
      cardId,
      paidBookingIds: result.paidBookingIds,
      totalFareRwf: result.totalFareRwf,
      balanceRwf: result.balanceRwf,
      message: tapMessage,
    });
  } catch (e) {
    const msg = String(e?.message || e);
    logger.warn("tapCardDeviceV2 failed", {error: msg});
    const code = e instanceof HttpsError ? e.code : "internal";
    try {
      const body = parseJsonBody(req);
      const data = body && body.data ? body.data : body;
      const rfidUid = normalizeRfidUid(data?.rfidUid);
      const cardId = await resolveCardFromInput({rfidUid, cardIdInput: ""});
      const ownerUid = await getCardOwnerUserId(cardId);
      if (ownerUid) {
        await createUserNotification({
          userId: ownerUid,
          type: "tap_result",
          title: "Tap failed",
          body: msg,
          data: {
            success: false,
            busId: String((data && data.busId) || ""),
            cardId,
            seatNo: Number.isInteger(Number(data?.seatNo)) ? Math.trunc(Number(data.seatNo)) : null,
            errorCode: code,
          },
        });
      }
    } catch (_) {}
    const status = code === "not-found" ? 404 :
      code === "permission-denied" ? 403 :
      code === "failed-precondition" ? 412 :
      code === "invalid-argument" ? 400 : 500;
    res.status(status).json({ok: false, error: code, message: msg});
  }
});

/**
 * Updates bus stop progress along the assigned direction.
 * This supports paid-seat release based on destination index.
 */
exports.updateBusProgressV2 = onCall({region: "us-central1"}, async (request) => {
  const caller = await requireSuperAdmin(request);
  const busId = String(request.data?.busId || "").trim();
  const currentStopIndex = Number(request.data?.currentStopIndex);

  if (!busId || !Number.isInteger(currentStopIndex) || currentStopIndex < 0) {
    throw new HttpsError("invalid-argument", "busId and valid currentStopIndex are required.");
  }

  const now = admin.firestore.Timestamp.now();
  await db.collection("bus_direction_assignments").doc(busId).set({
    currentStopIndex,
    updatedAt: now,
    updatedBy: caller.uid,
  }, {merge: true});

  return {ok: true, busId, currentStopIndex};
});

/**
 * Seat window check (foundation for booked->paid->free logic):
 * seat can be reused when
 * 1) request is opposite direction, OR
 * 2) request starts at/after paid trip destination stop, OR
 * 3) paid lock expired by time.
 */
exports.checkSeatWindowV2 = onCall({region: "us-central1"}, async (request) => {
  await requireAuth(request);
  const busId = String(request.data?.busId || "").trim();
  const seatNo = Number(request.data?.seatNo);
  const requestDirectionId = String(request.data?.directionId || "").trim();
  const requestOriginStopIndex = Number(request.data?.originStopIndex);
  const requestDestinationStopIndex = Number(request.data?.destinationStopIndex);

  if (!busId || !Number.isInteger(seatNo) || seatNo <= 0 || !requestDirectionId ||
      !Number.isInteger(requestOriginStopIndex) || requestOriginStopIndex < 0 ||
      !Number.isInteger(requestDestinationStopIndex) ||
      requestDestinationStopIndex <= requestOriginStopIndex) {
    throw new HttpsError("invalid-argument", "Invalid seat window payload.");
  }

  const lockRef = db.collection("seat_locks").doc(busId).collection("seats").doc(String(seatNo));
  const lockSnap = await lockRef.get();
  if (!lockSnap.exists) {
    return {ok: true, seatNo, available: true, reason: "no_lock"};
  }

  const lock = lockSnap.data() || {};
  const available = isSeatAvailableAgainstLock(
    lock,
    requestDirectionId,
    requestOriginStopIndex,
    requestDestinationStopIndex,
  );
  return {
    ok: true,
    seatNo,
    available,
    reason: available ? "non_overlapping_segment" : "overlap_or_opposite_direction",
  };
});

exports.v2ListCollectionsHint = onCall({region: "us-central1"}, async (request) => {
  await requireSuperAdmin(request);
  return {
    ok: true,
    message: "v2 core collections active.",
    activeCollections: [
      "traffic_users",
      "agency_applications",
      "agencies",
      "agency_members",
      "agency_secrets",
      "route_directions",
      "bus_direction_assignments",
      "agency_direction_fares",
      "card_registry",
      "seat_locks",
      "routes",
      "buses",
      "bookings",
      "card_transactions",
      "admin_events",
    ],
  };
});

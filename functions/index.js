const {onCall, HttpsError} = require("firebase-functions/v2/https");
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
  const caller = await requireAuth(request);
  const requestedAgencyId = String(request.data?.agencyId || "").trim();
  const agencyAccess = await requireAgencyAdmin(caller, requestedAgencyId || null);

  const agencyId = agencyAccess.agencyId;
  const directionId = String(request.data?.directionId || "").trim();
  const fromStopIndex = Number(request.data?.fromStopIndex);
  const toStopIndex = Number(request.data?.toStopIndex);
  const fareRwf = Number(request.data?.fareRwf);

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

  const directionSnap = await db.collection("route_directions").doc(directionId).get();
  if (!directionSnap.exists) {
    throw new HttpsError("not-found", "Direction not found.");
  }
  const direction = directionSnap.data() || {};
  const stops = Array.isArray(direction.stopNames) ? direction.stopNames : [];
  if (toStopIndex >= stops.length) {
    throw new HttpsError("invalid-argument", "Stop index out of bounds.");
  }

  const docId = `${agencyId}_${directionId}`;
  const key = `${fromStopIndex}_${toStopIndex}`;
  const now = admin.firestore.Timestamp.now();
  const fromStopName = String(stops[fromStopIndex] || "");
  const toStopName = String(stops[toStopIndex] || "");

  await db.collection("agency_direction_fares").doc(docId).set({
    agencyId,
    directionId,
    pairId: String(direction.pairId || ""),
    corridorName: String(direction.corridorName || ""),
    directionLabel: String(direction.directionLabel || ""),
    stopNames: stops,
    active: true,
    updatedAt: now,
    updatedBy: caller.uid,
    createdAt: now,
    faresBySegment: {
      [key]: {
        fareRwf: Math.trunc(fareRwf),
        fromStopIndex,
        toStopIndex,
        fromStopName,
        toStopName,
        updatedAt: now,
      },
    },
  }, {merge: true});

  logger.info("setAgencyDirectionFareV2", {
    by: caller.uid,
    agencyId,
    directionId,
    key,
    fareRwf: Math.trunc(fareRwf),
  });
  return {ok: true, agencyId, directionId, segmentKey: key, fareRwf: Math.trunc(fareRwf)};
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

  if (!busId || !Number.isInteger(seatNo) || seatNo <= 0 || !requestDirectionId ||
      !Number.isInteger(requestOriginStopIndex) || requestOriginStopIndex < 0) {
    throw new HttpsError("invalid-argument", "Invalid seat window payload.");
  }

  const lockRef = db.collection("seat_locks").doc(busId).collection("seats").doc(String(seatNo));
  const lockSnap = await lockRef.get();
  if (!lockSnap.exists) {
    return {ok: true, seatNo, available: true, reason: "no_lock"};
  }

  const lock = lockSnap.data() || {};
  const lockDirectionId = String(lock.directionId || "");
  const lockDestinationStopIndex = Number(lock.destinationStopIndex || -1);
  const releaseAtMs = Number(lock.releaseAtMs || 0);
  const nowMs = Date.now();

  if (lockDirectionId && lockDirectionId !== requestDirectionId) {
    return {ok: true, seatNo, available: true, reason: "opposite_direction"};
  }
  if (Number.isInteger(lockDestinationStopIndex) && requestOriginStopIndex >= lockDestinationStopIndex) {
    return {ok: true, seatNo, available: true, reason: "past_destination"};
  }
  if (releaseAtMs > 0 && nowMs >= releaseAtMs) {
    return {ok: true, seatNo, available: true, reason: "ttl_expired"};
  }
  return {ok: true, seatNo, available: false, reason: "occupied_on_segment"};
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
      "seat_locks",
      "routes",
      "buses",
      "bookings",
      "card_transactions",
      "admin_events",
    ],
  };
});

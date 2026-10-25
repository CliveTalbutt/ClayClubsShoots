'use strict';
// Payment providers: Stripe (cards, Apple Pay, Google Pay), PayPal, GoCardless
// (Direct Debit), Square and Mollie. Each provider can start a hosted checkout,
// confirm it when the customer returns, and receive webhooks for renewals. The
// return step verifies with the provider's API, so a first payment works even
// when webhooks cannot reach this machine.
const crypto = require('crypto');
const express = require('express');

const CURRENCY = (process.env.CURRENCY || 'GBP').toUpperCase();
const SYMBOLS = { GBP: '£', EUR: '€', USD: '$' };
const GRACE = 3 * 86400;

// Prices are per head (see allowance.js), so the amount is worked out for each club by planFor().
const PLANS = {
  annual: { key: 'annual', label: 'Annual subscription', pence: 0, months: 12, recurring: false, blurb: 'one payment, 12 months of access' },
  topup: { key: 'topup', label: 'Add shooters', pence: 0, months: 0, recurring: false, blurb: 'one payment for the rest of this subscription year' },
};
const allowanceLib = require('./allowance');
const amount = (plan) => (plan.pence / 100).toFixed(2);
const priceText = (plan) => `${SYMBOLS[CURRENCY] || CURRENCY + ' '}${amount(plan)}`;

const safeEq = (a, b) => {
  const x = Buffer.from(String(a || '')); const y = Buffer.from(String(b || ''));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};

async function http(method, url, { headers = {}, json, form } = {}) {
  const init = { method, headers: { Accept: 'application/json', ...headers }, signal: AbortSignal.timeout(20000) };
  if (json !== undefined) { init.body = JSON.stringify(json); init.headers['Content-Type'] = 'application/json'; }
  if (form) init.body = new URLSearchParams(form);
  const res = await fetch(url, init);
  const text = await res.text();
  let data;
  try { data = text ? JSON.parse(text) : {}; } catch { data = { raw: text }; }
  if (!res.ok) {
    const u = new URL(url);
    const e = new Error(`${method} ${u.host}${u.pathname} -> ${res.status}`);
    e.status = res.status; e.body = data;
    throw e;
  }
  return data;
}

module.exports = function createPayments({ db, baseUrl, needAuth, wrap }) {
  const now = () => Math.floor(Date.now() / 1000);
  const addMonths = (sec, m) => { const d = new Date(sec * 1000); d.setMonth(d.getMonth() + m); return Math.floor(d.getTime() / 1000); };
  const userById = (id) => db.prepare('SELECT * FROM users WHERE id = ?').get(id);
  const allowance = allowanceLib(db);
  const sizeOf = (u) => {
    const c = allowance.counts(u.id);
    const cur = u.est_members != null ? { m: u.est_members, g: u.est_guests } : { m: Math.max(1, c.members), g: c.guests };
    const next = u.req_members != null ? { m: u.req_members, g: u.req_guests } : cur;
    return { cur, next };
  };
  // The plan with this club's amount filled in.
  function planFor(user, key) {
    const base = PLANS[key];
    if (!base) return null;
    const { cur, next } = sizeOf(user);
    let pence;
    let blurb = `${next.m} member${next.m === 1 ? '' : 's'} + ${next.g} guest${next.g === 1 ? '' : 's'} for 12 months`;
    if (key === 'topup') {
      const left = Math.max(0, (user.sub_period_end || 0) - now());
      pence = Math.max(50, Math.ceil(Math.max(0, allowanceLib.price(next.m, next.g) - allowanceLib.price(cur.m, cur.g)) * left / (365 * 86400)));
      blurb = `${next.m} members + ${next.g} guests, charged for the rest of this year`;
    } else pence = allowanceLib.price(next.m, next.g);
    return { ...base, pence, blurb };
  }
  const hook = (name) => (/^https:\/\//.test(baseUrl) ? `${baseUrl}/webhook/${name}` : undefined);
  const returnUrl = (name) => `${baseUrl}/billing/return/${name}`;

  // ---- shared bookkeeping ----
  const currentEnd = (u) => (u.sub_status === 'active' ? u.sub_period_end || 0 : 0);
  function grantUntil(userId, until) {
    const u = userById(userId);
    if (!u) return;
    db.prepare("UPDATE users SET sub_status = 'active', sub_period_end = ? WHERE id = ?").run(Math.max(currentEnd(u), until), userId);
  }
  // Returns true the first time a payment reference is marked paid.
  function markPaid(provider, ref, userId, plan) {
    return db.transaction(() => {
      const row = db.prepare('SELECT status FROM payments WHERE provider = ? AND provider_ref = ?').get(provider, ref);
      if (row?.status === 'paid') return false;
      if (row) db.prepare("UPDATE payments SET status = 'paid' WHERE provider = ? AND provider_ref = ?").run(provider, ref);
      else db.prepare("INSERT INTO payments (user_id, provider, plan, provider_ref, status) VALUES (?,?,?,?, 'paid')").run(userId, provider, plan, ref);
      return true;
    })();
  }
  // One-off pass: extends from the later of now and the current expiry.
  function activatePass(provider, ref, userId, planKey) {
    if (!PLANS[planKey] || !markPaid(provider, ref, userId, planKey)) return;
    allowance.applyRequested(userId);
    const base = Math.max(now(), currentEnd(userById(userId)));
    grantUntil(userId, addMonths(base, PLANS[planKey].months));
  }
  // Recurring payment: access runs a period from when it was paid. Repeats are harmless.
  function activateRecurring(provider, ref, userId, planKey, paidAt) {
    if (!PLANS[planKey]) return;
    markPaid(provider, ref, userId, planKey);
    allowance.applyRequested(userId);
    grantUntil(userId, addMonths(paidAt, PLANS[planKey].months) + GRACE);
  }
  const addPending = (provider, ref, userId, plan, meta) =>
    db.prepare('INSERT OR REPLACE INTO payments (user_id, provider, plan, provider_ref, status, meta) VALUES (?,?,?,?,?,?)')
      .run(userId, provider, plan, ref, 'pending', meta ? JSON.stringify(meta) : null);
  const getPayment = (provider, ref, userId) => {
    const row = db.prepare('SELECT * FROM payments WHERE provider = ? AND provider_ref = ? AND user_id = ?').get(provider, ref, userId);
    return row && { ...row, meta: row.meta ? JSON.parse(row.meta) : {} };
  };
  const setLink = (provider, kind, id, userId, plan) =>
    db.prepare('INSERT OR REPLACE INTO pay_links (provider, kind, external_id, user_id, plan) VALUES (?,?,?,?,?)').run(provider, kind, id, userId, plan);
  const getLink = (provider, kind, id) => db.prepare('SELECT * FROM pay_links WHERE provider = ? AND kind = ? AND external_id = ?').get(provider, kind, id);
  const userLink = (provider, kind, userId) => db.prepare('SELECT * FROM pay_links WHERE provider = ? AND kind = ? AND user_id = ?').get(provider, kind, userId);

  // ---- Stripe ----
  const stripe = process.env.STRIPE_SECRET_KEY ? require('stripe')(process.env.STRIPE_SECRET_KEY) : null;
  function syncStripeSubscription(sub) {
    const end = sub.current_period_end || sub.items?.data?.[0]?.current_period_end || null;
    db.prepare('UPDATE users SET sub_status = ?, sub_period_end = ? WHERE stripe_customer_id = ?').run(sub.status, end, sub.customer);
  }
  async function stripeFulfil(s) {
    if (s.payment_status !== 'paid') return;
    if (s.mode === 'subscription' && s.subscription) syncStripeSubscription(await stripe.subscriptions.retrieve(s.subscription));
    else if (s.mode === 'payment') activatePass('stripe', s.payment_intent || s.id, Number(s.metadata.user_id), s.metadata.plan);
  }
  const stripeProvider = {
    id: 'stripe', name: 'Card, Apple Pay & Google Pay', plans: ['annual', 'topup'],
    enabled: () => !!stripe,
    async start(user, planKey) {
      const plan = planFor(user, planKey);
      let customer = user.stripe_customer_id;
      if (!customer) {
        customer = (await stripe.customers.create({ email: user.email, name: user.club_name, metadata: { user_id: String(user.id) } })).id;
        db.prepare('UPDATE users SET stripe_customer_id = ? WHERE id = ?').run(customer, user.id);
      }
      const session = await stripe.checkout.sessions.create({
        mode: plan.recurring ? 'subscription' : 'payment',
        customer,
        line_items: [{ quantity: 1, price_data: {
          currency: CURRENCY.toLowerCase(), unit_amount: plan.pence,
          product_data: { name: `Clay Shoots – ${plan.label}` },
          ...(plan.recurring ? { recurring: { interval: 'month' } } : {}),
        } }],
        metadata: { user_id: String(user.id), plan: planKey },
        success_url: `${returnUrl('stripe')}?session_id={CHECKOUT_SESSION_ID}`,
        cancel_url: `${baseUrl}/dashboard?pay=cancelled`,
      });
      return session.url;
    },
    async complete(user, q) {
      const s = await stripe.checkout.sessions.retrieve(String(q.session_id || ''));
      if (String(s.metadata?.user_id) !== String(user.id)) throw new Error('Stripe session does not belong to this user');
      await stripeFulfil(s);
    },
    async webhook(req) {
      if (!process.env.STRIPE_WEBHOOK_SECRET) return 503;
      let event;
      try { event = stripe.webhooks.constructEvent(req.body, req.headers['stripe-signature'], process.env.STRIPE_WEBHOOK_SECRET); } catch { return 400; }
      if (event.type === 'checkout.session.completed') await stripeFulfil(event.data.object);
      else if (event.type.startsWith('customer.subscription.')) syncStripeSubscription(event.data.object);
      return 200;
    },
  };

  // ---- PayPal ----
  const paypalBase = () => process.env.PAYPAL_BASE || (process.env.PAYPAL_ENV === 'live' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com');
  let paypalToken = { value: null, expires: 0 };
  async function paypalAuth() {
    if (paypalToken.value && paypalToken.expires > Date.now() + 30000) return paypalToken.value;
    const basic = Buffer.from(`${process.env.PAYPAL_CLIENT_ID}:${process.env.PAYPAL_CLIENT_SECRET}`).toString('base64');
    const r = await http('POST', `${paypalBase()}/v1/oauth2/token`, { headers: { Authorization: `Basic ${basic}` }, form: { grant_type: 'client_credentials' } });
    paypalToken = { value: r.access_token, expires: Date.now() + r.expires_in * 1000 };
    return r.access_token;
  }
  const paypal = async (method, path, json) => http(method, `${paypalBase()}${path}`, { headers: { Authorization: `Bearer ${await paypalAuth()}` }, json });
  const approvalLink = (r) => r.links.find((l) => ['payer-action', 'approve'].includes(l.rel))?.href;
  async function syncPaypalSubscription(id) {
    const link = getLink('paypal', 'subscription', id);
    if (!link) return;
    const s = await paypal('GET', `/v1/billing/subscriptions/${encodeURIComponent(id)}`);
    if (s.status !== 'ACTIVE') return;
    const next = s.billing_info?.next_billing_time ? Date.parse(s.billing_info.next_billing_time) / 1000 : addMonths(now(), 1);
    markPaid('paypal', id, link.user_id, 'monthly');
    grantUntil(link.user_id, next + GRACE);
  }
  const paypalProvider = {
    id: 'paypal', name: 'PayPal',
    get plans() { return process.env.PAYPAL_PLAN_ID ? ['annual', 'topup'] : ['annual']; },
    enabled: () => !!(process.env.PAYPAL_CLIENT_ID && process.env.PAYPAL_CLIENT_SECRET),
    async start(user, planKey) {
      const plan = planFor(user, planKey);
      const urls = { return_url: returnUrl('paypal'), cancel_url: `${baseUrl}/dashboard?pay=cancelled` };
      if (plan.recurring) {
        const sub = await paypal('POST', '/v1/billing/subscriptions', {
          plan_id: process.env.PAYPAL_PLAN_ID, custom_id: `${user.id}:${planKey}`,
          subscriber: { email_address: user.email },
          application_context: { brand_name: 'Clay Shoots', user_action: 'SUBSCRIBE_NOW', shipping_preference: 'NO_SHIPPING', ...urls },
        });
        addPending('paypal', sub.id, user.id, planKey);
        setLink('paypal', 'subscription', sub.id, user.id, planKey);
        return approvalLink(sub);
      }
      const order = await paypal('POST', '/v2/checkout/orders', {
        intent: 'CAPTURE',
        purchase_units: [{ custom_id: `${user.id}:${planKey}`, description: `Clay Shoots – ${plan.label}`, amount: { currency_code: CURRENCY, value: amount(plan) } }],
        payment_source: { paypal: { experience_context: { ...urls, user_action: 'PAY_NOW', shipping_preference: 'NO_SHIPPING' } } },
      });
      addPending('paypal', order.id, user.id, planKey);
      return approvalLink(order);
    },
    async complete(user, q) {
      if (q.subscription_id) {
        const id = String(q.subscription_id);
        if (getLink('paypal', 'subscription', id)?.user_id !== user.id) throw new Error('PayPal subscription does not belong to this user');
        return syncPaypalSubscription(id);
      }
      const id = String(q.token || '');
      const row = getPayment('paypal', id, user.id);
      if (!row) throw new Error('Unknown PayPal order');
      if (row.status === 'paid') return;
      const cap = await paypal('POST', `/v2/checkout/orders/${encodeURIComponent(id)}/capture`, {});
      if (cap.status === 'COMPLETED') activatePass('paypal', id, user.id, row.plan);
    },
    async webhook(req) {
      if (!process.env.PAYPAL_WEBHOOK_ID) return 503;
      const h = req.headers;
      let event;
      try { event = JSON.parse(req.body.toString('utf8')); } catch { return 400; }
      const v = await paypal('POST', '/v1/notifications/verify-webhook-signature', {
        auth_algo: h['paypal-auth-algo'], cert_url: h['paypal-cert-url'], transmission_id: h['paypal-transmission-id'],
        transmission_sig: h['paypal-transmission-sig'], transmission_time: h['paypal-transmission-time'],
        webhook_id: process.env.PAYPAL_WEBHOOK_ID, webhook_event: event,
      });
      if (v.verification_status !== 'SUCCESS') return 400;
      const subId = event.event_type === 'PAYMENT.SALE.COMPLETED' ? event.resource?.billing_agreement_id
        : String(event.event_type).startsWith('BILLING.SUBSCRIPTION.') ? event.resource?.id : null;
      if (subId) await syncPaypalSubscription(subId);
      return 200;
    },
  };

  // ---- GoCardless (Direct Debit) ----
  const gcBase = () => process.env.GOCARDLESS_BASE || (process.env.GOCARDLESS_ENV === 'live' ? 'https://api.gocardless.com' : 'https://api-sandbox.gocardless.com');
  const gc = (method, path, json) => http(method, `${gcBase()}${path}`, {
    headers: { Authorization: `Bearer ${process.env.GOCARDLESS_ACCESS_TOKEN}`, 'GoCardless-Version': '2015-07-06' }, json,
  });
  async function gcPayment(id) {
    const { payments: p } = await gc('GET', `/payments/${encodeURIComponent(id)}`);
    const sub = p.links?.subscription ? getLink('gocardless', 'subscription', p.links.subscription) : null;
    const userId = sub?.user_id ?? Number(p.metadata?.user_id);
    const planKey = sub?.plan ?? p.metadata?.plan;
    if (!userId || !PLANS[planKey]) return;
    if (PLANS[planKey].recurring) activateRecurring('gocardless', id, userId, planKey, Date.parse(p.charge_date) / 1000 || now());
    else activatePass('gocardless', id, userId, planKey);
  }
  const gocardlessProvider = {
    id: 'gocardless', name: 'Direct Debit (GoCardless)', plans: ['annual', 'topup'],
    enabled: () => !!process.env.GOCARDLESS_ACCESS_TOKEN,
    async start(user, planKey) {
      const sessionToken = crypto.randomBytes(16).toString('hex');
      const { redirect_flows: flow } = await gc('POST', '/redirect_flows', { redirect_flows: {
        description: `Clay Shoots – ${PLANS[planKey].label}`, session_token: sessionToken,
        success_redirect_url: returnUrl('gocardless'), prefilled_customer: { email: user.email },
      } });
      addPending('gocardless', flow.id, user.id, planKey, { sessionToken });
      return flow.redirect_url;
    },
    async complete(user, q) {
      const id = String(q.redirect_flow_id || '');
      const row = getPayment('gocardless', id, user.id);
      if (!row) throw new Error('Unknown GoCardless redirect flow');
      if (row.status === 'paid') return;
      const { redirect_flows: flow } = await gc('POST', `/redirect_flows/${encodeURIComponent(id)}/actions/complete`, { data: { session_token: row.meta.sessionToken } });
      const mandate = flow.links.mandate;
      const plan = planFor(user, row.plan);
      const metadata = { user_id: String(user.id), plan: row.plan };
      if (plan.recurring) {
        const { subscriptions: sub } = await gc('POST', '/subscriptions', { subscriptions: {
          amount: plan.pence, currency: CURRENCY, name: `Clay Shoots – ${plan.label}`, interval_unit: 'monthly', links: { mandate }, metadata,
        } });
        setLink('gocardless', 'subscription', sub.id, user.id, row.plan);
      } else {
        await gc('POST', '/payments', { payments: { amount: plan.pence, currency: CURRENCY, description: `Clay Shoots – ${plan.label}`, links: { mandate }, metadata } });
      }
      markPaid('gocardless', id, user.id, row.plan);
      // Direct Debit takes a few days to confirm, so give a short provisional period.
      grantUntil(user.id, now() + 7 * 86400);
    },
    async webhook(req) {
      if (!process.env.GOCARDLESS_WEBHOOK_SECRET) return 503;
      const expected = crypto.createHmac('sha256', process.env.GOCARDLESS_WEBHOOK_SECRET).update(req.body).digest('hex');
      if (!safeEq(expected, req.headers['webhook-signature'])) return 498;
      let events;
      try { events = JSON.parse(req.body.toString('utf8')).events || []; } catch { return 400; }
      for (const e of events) {
        if (e.resource_type === 'payments' && ['confirmed', 'paid_out'].includes(e.action) && e.links?.payment) await gcPayment(e.links.payment);
      }
      return 200;
    },
  };

  // ---- Square (one-off annual pass via a hosted payment link) ----
  const squareBase = () => process.env.SQUARE_BASE || (process.env.SQUARE_ENV === 'live' ? 'https://connect.squareup.com' : 'https://connect.squareupsandbox.com');
  const square = (method, path, json) => http(method, `${squareBase()}${path}`, {
    headers: { Authorization: `Bearer ${process.env.SQUARE_ACCESS_TOKEN}`, 'Square-Version': '2024-10-17' }, json,
  });
  async function squareFulfil(orderId, userId, planKey) {
    const { order } = await square('GET', `/v2/orders/${encodeURIComponent(orderId)}`);
    if (order?.state === 'COMPLETED') activatePass('square', orderId, userId, planKey);
  }
  const squareProvider = {
    id: 'square', name: 'Square', plans: ['annual', 'topup'],
    enabled: () => !!(process.env.SQUARE_ACCESS_TOKEN && process.env.SQUARE_LOCATION_ID),
    async start(user, planKey) {
      const plan = planFor(user, planKey);
      const { payment_link: link } = await square('POST', '/v2/online-checkout/payment-links', {
        idempotency_key: crypto.randomUUID(),
        quick_pay: { name: `Clay Shoots – ${plan.label}`, price_money: { amount: plan.pence, currency: CURRENCY }, location_id: process.env.SQUARE_LOCATION_ID },
        checkout_options: { redirect_url: returnUrl('square') },
        pre_populated_data: { buyer_email: user.email },
      });
      addPending('square', link.order_id, user.id, planKey);
      return link.url;
    },
    async complete(user) {
      const rows = db.prepare("SELECT * FROM payments WHERE provider = 'square' AND user_id = ? AND status = 'pending' ORDER BY id DESC LIMIT 5").all(user.id);
      for (const r of rows) await squareFulfil(r.provider_ref, user.id, r.plan);
    },
    async webhook(req) {
      const key = process.env.SQUARE_WEBHOOK_SIGNATURE_KEY;
      if (!key) return 503;
      const expected = crypto.createHmac('sha256', key).update(`${baseUrl}/webhook/square${req.body.toString('utf8')}`).digest('base64');
      if (!safeEq(expected, req.headers['x-square-hmacsha256-signature'])) return 498;
      let event;
      try { event = JSON.parse(req.body.toString('utf8')); } catch { return 400; }
      const obj = event.data?.object || {};
      const orderId = obj.payment?.order_id || obj.order_updated?.order_id;
      const row = orderId && db.prepare("SELECT * FROM payments WHERE provider = 'square' AND provider_ref = ?").get(orderId);
      if (row) await squareFulfil(orderId, row.user_id, row.plan);
      return 200;
    },
  };

  // ---- Mollie (cards, iDEAL, Bancontact, SEPA and more) ----
  const mollieBase = () => process.env.MOLLIE_BASE || 'https://api.mollie.com/v2';
  const mollie = (method, path, json) => http(method, `${mollieBase()}${path}`, { headers: { Authorization: `Bearer ${process.env.MOLLIE_API_KEY}` }, json });
  async function mollieFulfil(paymentId) {
    const p = await mollie('GET', `/payments/${encodeURIComponent(paymentId)}`);
    const userId = Number(p.metadata?.user_id);
    const planKey = p.metadata?.plan;
    if (p.status !== 'paid' || !userId || !PLANS[planKey]) return;
    const plan = PLANS[planKey];
    if (!plan.recurring) return activatePass('mollie', p.id, userId, planKey);
    activateRecurring('mollie', p.id, userId, planKey, Date.parse(p.paidAt) / 1000 || now());
    if (p.sequenceType === 'first' && p.customerId && !userLink('mollie', 'subscription', userId)) {
      const start = new Date(addMonths(now(), 1) * 1000).toISOString().slice(0, 10);
      const sub = await mollie('POST', `/customers/${encodeURIComponent(p.customerId)}/subscriptions`, {
        amount: { currency: CURRENCY, value: amount(plan) }, interval: '1 month', startDate: start,
        description: `Clay Shoots – ${plan.label}`, webhookUrl: hook('mollie'), metadata: { user_id: String(userId), plan: planKey },
      });
      setLink('mollie', 'subscription', sub.id, userId, planKey);
    }
  }
  const mollieProvider = {
    id: 'mollie', name: 'Mollie (iDEAL, Bancontact, SEPA & more)', plans: ['annual', 'topup'],
    enabled: () => !!process.env.MOLLIE_API_KEY,
    async start(user, planKey) {
      const plan = planFor(user, planKey);
      let customerId;
      if (plan.recurring) {
        customerId = userLink('mollie', 'customer', user.id)?.external_id;
        if (!customerId) {
          customerId = (await mollie('POST', '/customers', { name: user.club_name, email: user.email, metadata: { user_id: String(user.id) } })).id;
          setLink('mollie', 'customer', customerId, user.id, null);
        }
      }
      const p = await mollie('POST', '/payments', {
        amount: { currency: CURRENCY, value: amount(plan) }, description: `Clay Shoots – ${plan.label}`,
        redirectUrl: returnUrl('mollie'), webhookUrl: hook('mollie'),
        ...(plan.recurring ? { customerId, sequenceType: 'first' } : {}),
        metadata: { user_id: String(user.id), plan: planKey },
      });
      addPending('mollie', p.id, user.id, planKey);
      return p._links.checkout.href;
    },
    async complete(user) {
      const rows = db.prepare("SELECT * FROM payments WHERE provider = 'mollie' AND user_id = ? AND status = 'pending' ORDER BY id DESC LIMIT 5").all(user.id);
      for (const r of rows) await mollieFulfil(r.provider_ref);
    },
    async webhook(req) {
      // Mollie sends no signature; the payment is re-fetched from the API with our key.
      const id = new URLSearchParams(req.body.toString('utf8')).get('id');
      if (!/^tr_\w+$/.test(id || '')) return 400;
      await mollieFulfil(id);
      return 200;
    },
  };

  // ---- Dummy provider: a fake card checkout for development and demos. Never enabled in production. ----
  const dummyProvider = {
    id: 'dummy', name: 'test card (dummy payment)', plans: ['annual', 'topup'],
    enabled: () => process.env.PAYMENTS_DUMMY === '1' && process.env.NODE_ENV !== 'production',
    async start(user, planKey) { return `${baseUrl}/billing/dummy/checkout?plan=${encodeURIComponent(planKey)}`; },
    async complete() {},
    async webhook() { return 200; },
  };

  const providers = Object.fromEntries([dummyProvider, stripeProvider, paypalProvider, gocardlessProvider, squareProvider, mollieProvider].map((p) => [p.id, p]));
  const enabledProviders = () => Object.values(providers).filter((p) => p.enabled());

  // Which providers can take each plan, for the dashboard.
  // True when a mid-year top-up applies: an active subscription with a larger requested allowance.
  const topupApplies = (u) => {
    if (!u || u.is_super === 1 || !(u.sub_period_end > now()) || u.sub_status !== 'active') return false;
    const { cur, next } = sizeOf(u);
    return allowanceLib.price(next.m, next.g) > allowanceLib.price(cur.m, cur.g);
  };
  const eligible = (u, key) => key === 'annual' || (key === 'topup' && topupApplies(u));

  // Which providers can take each plan for this club, for the dashboard.
  const options = (user) => Object.keys(PLANS).filter((k) => eligible(user, k)).map((k) => {
    const plan = planFor(user, k);
    return {
      key: plan.key, label: plan.label, price: priceText(plan), blurb: plan.blurb,
      providers: enabledProviders().filter((p) => p.plans.includes(plan.key)).map((p) => ({ id: p.id, name: p.name })),
    };
  }).filter((o) => o.providers.length);

  // Current and requested allowance with prices, for the dashboard.
  const allowanceInfo = (user) => {
    const { cur, next } = sizeOf(user);
    const c = allowance.counts(user.id);
    return {
      limited: allowance.get(user.id).limited, members: cur.m, guests: cur.g, usedMembers: c.members, usedGuests: c.guests,
      nextMembers: next.m, nextGuests: next.g, pending: user.req_members != null,
      price: allowanceLib.money(allowanceLib.price(cur.m, cur.g)), nextPrice: allowanceLib.money(allowanceLib.price(next.m, next.g)),
    };
  };

  // ---- routes ----
  const webhooks = express.Router();
  webhooks.post('/:provider', express.raw({ type: '*/*', limit: '1mb' }), wrap(async (req, res) => {
    const p = providers[req.params.provider];
    if (!p?.enabled()) return res.sendStatus(404);
    try { res.sendStatus(await p.webhook(req)); } catch (e) { console.error('webhook', p.id, e.message, e.body || ''); res.sendStatus(500); }
  }));

  const billing = express.Router();
  billing.post('/pay/:provider', needAuth, wrap(async (req, res) => {
    const p = providers[req.params.provider];
    const planKey = String(req.body.plan || '');
    if (res.locals.userRole === 'Member') return res.status(403).send('Only a club admin can manage the subscription');
    if (!p?.enabled() || !p.plans.includes(planKey) || !eligible(res.locals.user, planKey)) return res.status(400).send('Unsupported payment option');
    try {
      const url = await p.start(res.locals.user, planKey);
      if (!/^https?:\/\//.test(url || '')) throw new Error('No checkout URL returned');
      res.redirect(303, url);
    } catch (e) {
      console.error('checkout', p.id, e.message, e.body ? JSON.stringify(e.body).slice(0, 500) : '');
      res.redirect('/dashboard?pay=failed');
    }
  }));
  billing.get('/return/:provider', needAuth, wrap(async (req, res) => {
    const p = providers[req.params.provider];
    if (!p?.enabled()) return res.sendStatus(404);
    try {
      await p.complete(res.locals.user, req.query);
      const u = userById(res.locals.user.id);
      res.redirect(`/dashboard?pay=${u.sub_status === 'active' && (u.sub_period_end || 0) > now() ? 'ok' : 'pending'}`);
    } catch (e) {
      console.error('return', p.id, e.message, e.body ? JSON.stringify(e.body).slice(0, 500) : '');
      res.redirect('/dashboard?pay=failed');
    }
  }));
  billing.get('/dummy/checkout', needAuth, (req, res) => {
    const plan = dummyProvider.enabled() && eligible(res.locals.user, String(req.query.plan || '')) ? planFor(res.locals.user, String(req.query.plan)) : null;
    if (!plan) return res.status(404).send('Not found');
    res.render('dummy-checkout', { plan, price: priceText(plan) });
  });
  billing.post('/dummy/confirm', needAuth, wrap(async (req, res) => {
    const plan = dummyProvider.enabled() && eligible(res.locals.user, String(req.body.plan || '')) ? planFor(res.locals.user, String(req.body.plan)) : null;
    if (!plan || res.locals.userRole === 'Member') return res.status(404).send('Not found');
    if (req.body.outcome !== 'pay') return res.redirect('/dashboard?pay=cancelled');
    const ref = `dummy_${crypto.randomUUID()}`;
    const uid = res.locals.user.id;
    if (plan.recurring) activateRecurring('dummy', ref, uid, plan.key, now());
    else activatePass('dummy', ref, uid, plan.key);
    res.redirect('/dashboard?pay=ok');
  }));
  billing.post('/allowance', needAuth, (req, res) => {
    if (res.locals.userRole === 'Member') return res.status(403).send('Only a club admin can manage the subscription');
    const m = allowanceLib.parseCount(req.body.members, { min: 1 });
    const g = allowanceLib.parseCount(req.body.guests);
    if (m == null || g == null) return res.redirect('/dashboard?pay=badsize#subscription');
    const err = allowance.request(res.locals.user.id, m, g);
    res.redirect(err ? `/dashboard?pay=badsize&msg=${encodeURIComponent(err)}#subscription` : '/dashboard?pay=requested#subscription');
  });
  billing.post('/portal', needAuth, wrap(async (req, res) => {
    const u = res.locals.user;
    if (!stripe || !u.stripe_customer_id) return res.redirect('/dashboard');
    const s = await stripe.billingPortal.sessions.create({ customer: u.stripe_customer_id, return_url: `${baseUrl}/dashboard` });
    res.redirect(303, s.url);
  }));

  return { providers, enabledProviders, anyEnabled: () => enabledProviders().length > 0, options, allowanceInfo, webhooks, billing, PLANS, hasStripePortal: !!stripe };
};

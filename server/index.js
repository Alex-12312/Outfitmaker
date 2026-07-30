require('dotenv').config();
const express = require('express');
const cors = require('cors');
const Stripe = require('stripe');

const app = express();
app.use(cors());

// Use JSON for normal endpoints and raw body for webhook endpoint
app.use(express.json());

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY, { apiVersion: '2022-11-15' });

// Create a Checkout Session for a subscription
app.post('/create-checkout-session', async (req, res) => {
  const { email } = req.body;
  try {
    const session = await stripe.checkout.sessions.create({
      payment_method_types: ['card'],
      mode: 'subscription',
      line_items: [{ price: process.env.STRIPE_PRICE_ID, quantity: 1 }],
      customer_email: email,
      success_url: `${process.env.SUCCESS_URL || 'https://example.com/success'}?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: process.env.CANCEL_URL || 'https://example.com/cancel',
    });

    res.json({ url: session.url });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

// Stripe webhook endpoint to listen for subscription events
app.post('/webhook', express.raw({ type: 'application/json' }), (req, res) => {
  const sig = req.headers['stripe-signature'];
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET;

  let event;
  try {
    if (webhookSecret) {
      event = stripe.webhooks.constructEvent(req.body, sig, webhookSecret);
    } else {
      // If no webhook secret is configured, parse the body directly (less secure).
      event = JSON.parse(req.body.toString());
    }
  } catch (err) {
    console.error('Webhook signature verification failed.', err.message);
    return res.status(400).send(`Webhook Error: ${err.message}`);
  }

  // Handle the checkout.session.completed event to provision access
  if (event.type === 'checkout.session.completed') {
    const session = event.data.object;
    console.log('Checkout session completed for', session.customer_email);
    // TODO: mark the user as premium in your database using session.customer_email
  }

  // Handle subscription updates
  if (event.type === 'invoice.payment_succeeded') {
    console.log('Invoice succeeded:', event.data.object);
  }

  res.json({ received: true });
});

// Simple endpoint to check whether a customer email has an active subscription
app.get('/subscription-status', async (req, res) => {
  const email = req.query.email;
  if (!email) return res.status(400).json({ error: 'Missing email query parameter' });

  try {
    const customers = await stripe.customers.list({ email });
    const customer = customers.data[0];
    if (!customer) return res.json({ isActive: false });

    const subs = await stripe.subscriptions.list({ customer: customer.id, limit: 10 });
    const active = subs.data.some(s => s.status === 'active' || s.status === 'trialing');
    return res.json({ isActive: active });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: err.message });
  }
});

const port = process.env.PORT || 4242;
app.listen(port, () => console.log(`Stripe backend listening on port ${port}`));

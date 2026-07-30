OutfitMaker Stripe backend

This is a minimal Node.js/Express example that creates Stripe Checkout sessions for recurring subscriptions and accepts webhooks.

Setup
1. Copy .env.example to .env and fill in your Stripe secret key, price id and webhook secret:

   cp .env.example .env
   # then edit .env and add your keys

2. Install dependencies:
   npm install

3. Start the server (development):
   npm run dev

Endpoints
- POST /create-checkout-session
  Body: { "email": "user@example.com" }
  Returns: { "url": "https://checkout.stripe.com/...." }

- POST /webhook
  Receives Stripe webhook events. Configure your webhook endpoint in the Stripe Dashboard to point to /webhook and set STRIPE_WEBHOOK_SECRET.

How it works
- The Flutter app calls /create-checkout-session to get a hosted Stripe Checkout URL for a subscription.
- The app opens the URL in the browser; the user completes payment on Stripe's hosted page.
- Stripe calls /webhook for important events (checkout.session.completed, invoice.payment_succeeded, customer.subscription.updated). Use those events to mark the user as premium in your database.

Security
- Do NOT commit your real secret keys to source control. Use environment variables on your server.
- Verify webhook signatures using STRIPE_WEBHOOK_SECRET.

Next steps
- Add a database and persist the subscription status tied to the customer's email.
- Add an endpoint the app can call to check subscription status (e.g., GET /subscription-status?email=...).

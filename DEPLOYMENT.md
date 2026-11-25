# Registry Deployment Guide

Registry offers multiple deployment options to meet your organization's specific needs, from quick cloud deployment to enterprise self-hosting.

## Self-Hosting (Recommended)

Self-hosting Registry gives you complete control over your data, unlimited customization capabilities, and cost-effective scaling.

### Why Self-Host?

**Data Ownership & Privacy**
- Complete control over sensitive student and family data
- Deploy in your own secure environment
- Meet specific compliance requirements (FERPA, GDPR, etc.)
- No third-party data sharing or storage concerns

**Cost Effectiveness**
- No monthly subscription fees
- Pay only for your infrastructure costs
- Scale economically with your organization's growth
- Avoid vendor lock-in and pricing changes

**Unlimited Customization**
- Modify workflows to match your specific processes
- Integrate with existing systems and databases
- Custom reporting and analytics
- White-label the interface with your branding

### Self-Hosting Options

#### Option 1: Docker Deployment (Easiest)

```bash
# Clone the repository
git clone https://github.com/perigrin/Registry.git
cd Registry

# Start with Docker Compose
docker-compose up -d

# Registry available at http://localhost:3000
```

#### Option 2: Cloud Provider Deployment

Deploy on any cloud provider:
- **AWS**: Use ECS, EC2, or Elastic Beanstalk
- **Google Cloud**: Deploy to Cloud Run or GKE
- **Azure**: Use Container Instances or AKS
- **DigitalOcean**: App Platform or Droplets
- **Linode**: Kubernetes Engine or Compute Instances

#### Option 3: On-Premises Deployment

For maximum security and control:
- Deploy on your own servers
- Integrate with existing infrastructure
- Use your existing database systems
- Custom network and security configurations

### Self-Hosting Support

**Community Support (Free)**
- GitHub Issues and Discussions
- Community documentation and guides
- Community-contributed plugins and extensions

**Enterprise Support (Paid)**
- Professional deployment assistance
- Custom development and integrations
- Priority support and training
- SLA guarantees and dedicated support team

Contact: enterprise@registry.com

---

## Render.com Deployment (Quick Demo)

For quick demos and evaluations, deploy Registry to Render.com:

### Prerequisites

1. GitHub repository with Registry codebase
2. Render.com account
3. Stripe account for payment processing (optional for demo)

### Quick Deploy

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/perigrin/Registry)

### Manual Deployment Steps

#### 1. Database Setup

The `render.yaml` blueprint automatically creates a PostgreSQL database named `registry-postgres`.

#### 2. Environment Variables

Set these environment variables in your Render dashboard:

**Required:**
- `DB_URL` - Automatically set from database
- `REGISTRY_SECRET` - Auto-generated secure secret
- `MOJO_MODE` - Set to `production`. In every mode except `development` and
  `test` the session cookie (and the `as-tenant` cookie, should the app ever set
  one) is `Secure`, `HttpOnly` and `SameSite=Lax`. This keys on the mode, not the
  request scheme, so a production deploy must be served over HTTPS, and a local
  run over plain HTTP must set `MOJO_MODE=development` or login will not stick

**Optional (for Stripe integration):**
- `STRIPE_PUBLIC_KEY` - Your Stripe publishable key
- `STRIPE_SECRET_KEY` - Your Stripe secret key  
- `STRIPE_WEBHOOK_SECRET` - Your Stripe webhook endpoint secret
- `STRIPE_CONNECT_WEBHOOK_SECRET` - The signing secret of the Connect webhook
  endpoint (`/webhooks/stripe/connect`), which receives events on sellers'
  own accounts. Required in production: without it every Connect delivery is
  refused and no such event settles

**Required in production (the platform's own Stripe account and first admin):**
- `PLATFORM_STRIPE_ACCOUNT_ID` - Tamarou's Stripe account id (`acct_...`)
- `PLATFORM_STRIPE_READY` - `true` once Stripe has approved that account, else `false`
- `PLATFORM_ADMIN_EMAIL` - the address of the platform tenant's first admin,
  who signs in by magic link to it

`docker-entrypoint.sh` runs `./registry platform bootstrap` after the schema
deploy, which writes the Stripe values onto the `registry` tenant and gives the
`registry` tenant's primary admin the configured email address (creating that
admin if the platform tenant has no admin-role member). With `MOJO_MODE=production`
a missing or malformed value stops the boot; elsewhere it is a warning. So does
a `PLATFORM_ADMIN_EMAIL` that already belongs to another user (a studio's, say):
bootstrap reports it as in use and writes nothing. If the `registry` tenant
already records a different Stripe account (one an admin set since), bootstrap
keeps it and its readiness as they are, and prints a warning naming both.
See [the platform tenant bootstrap runbook](docs/operations/platform-tenant-bootstrap.md)
for the pre-deploy checks, running the bootstrap by hand and verifying it.

**Email Configuration:**
- `EMAIL_FROM` - Default: `noreply@registry-demo.onrender.com`
- `SUPPORT_EMAIL` - Default: `support@registry-demo.onrender.com`

#### 3. Services Deployed

The blueprint creates:

1. **Web Service** (`registry-app`)
   - Main application server
   - Handles HTTP requests
   - Auto-scaling enabled

2. **Worker Service** (`registry-worker`)  
   - Background job processing
   - Handles email notifications
   - Payment processing tasks

3. **Scheduler Service** (`registry-scheduler`)
   - Runs every 5 minutes
   - Waitlist expiration processing

#### 4. Initial Setup

After deployment:

1. Visit your app URL to see the marketing page
2. Click "Start Your Tiny Art Empire" to begin tenant onboarding
3. Complete the registration steps
4. Access your tenant dashboard

### Demo Flow

#### Marketing Landing Page
- Visit: `https://your-app-name.onrender.com`
- Professional marketing page with features and pricing
- Clear call-to-action for signing up

#### Tenant Onboarding
1. **Welcome** - Introduction and process overview
2. **Profile** - Organization details and subdomain selection
3. **Team Setup** - Add admin user and team members
4. **Review** - Confirm the details and accept a platform offer (on day one, Solo: $0 plus 2.5% of each sale). There is no card or subscription step: accepting the offer creates the tenant.
5. **Completion** - Success page with next steps

#### Tenant Features
- Multi-child registration workflows
- Attendance tracking and reporting
- Payment processing and billing
- Parent-teacher communication
- Waitlist management
- Admin dashboards and analytics

### Health Monitoring

The application includes:
- Health check endpoint: `/health`
- Database connectivity verification
- Automatic service restart on failure

### Troubleshooting

#### Database Connection Issues
Check the `DB_URL` environment variable and database status in Render dashboard.

#### Application Won't Start
1. Check build logs for dependency installation errors
2. Verify all required environment variables are set
3. Check database migration status

#### Stripe Integration Issues  
1. Verify Stripe keys are correctly set
2. Check webhook endpoint configuration
3. Review Stripe dashboard for failed payments

### Performance Considerations

#### Scaling
- Web service auto-scales based on CPU/memory usage
- Worker service handles background jobs independently
- Database connection pooling enabled

#### Optimization
- Static assets served via CDN
- Database queries optimized with indexes
- Background job processing for heavy operations

### Security Features

- Input validation and sanitization
- CSRF protection on all forms
- SQL injection prevention
- XSS protection
- Secure session management: the session cookie and the `as-tenant` cookie are
  `Secure`, `HttpOnly` and `SameSite=Lax` in every `MOJO_MODE` except
  `development` and `test`, keyed on the mode and not the request scheme.
  `Lax` keeps the session on the Stripe 3-D Secure return and on magic-link
  login, both top-level GET navigations
- Environment-based configuration

### Monitoring & Logs

Access logs through Render dashboard:
- Application logs: Web service logs
- Background jobs: Worker service logs
- Database operations: Database logs
- Performance metrics: Built-in monitoring

### Demo Data

The application includes:
- Sample workflows and templates
- Test program types and configurations
- Demo outcome definitions
- Example pricing plans

### Support

For deployment issues:
- Check Render service logs
- Review environment variable configuration
- Verify database connectivity
- Contact support with specific error messages

### Next Steps

After successful deployment:
1. Configure custom domain (optional)
2. Set up monitoring and alerts
3. Configure backup strategies
4. Plan for production scaling
5. Implement additional security measures

---

**Note**: This deployment configuration is optimized for demo purposes. For production use, consider additional security hardening, backup strategies, and scaling configurations.
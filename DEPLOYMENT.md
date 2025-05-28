# Registry Deployment Guide

## Render.com Deployment

This guide walks you through deploying Registry to Render.com for a live demo.

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
- `MOJO_MODE` - Set to `production`

**Optional (for Stripe integration):**
- `STRIPE_PUBLIC_KEY` - Your Stripe publishable key
- `STRIPE_SECRET_KEY` - Your Stripe secret key  
- `STRIPE_WEBHOOK_SECRET` - Your Stripe webhook endpoint secret

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
   - Attendance checking
   - Waitlist expiration processing

#### 4. Initial Setup

After deployment:

1. Visit your app URL to see the marketing page
2. Click "Start Your Free Trial" to begin tenant onboarding
3. Complete the 5-step registration process
4. Access your tenant dashboard

### Demo Flow

#### Marketing Landing Page
- Visit: `https://your-app-name.onrender.com`
- Professional marketing page with features and pricing
- Clear call-to-action for starting trial

#### Tenant Onboarding (5 steps)
1. **Welcome** - Introduction and process overview
2. **Profile** - Organization details and subdomain selection  
3. **Team Setup** - Add admin user and team members
4. **Review** - Confirm all details before payment
5. **Payment** - Stripe integration for subscription setup
6. **Completion** - Success page with next steps

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
- Secure session management
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
# Registry - Registration software for events

Registry is an educational platform for after-school programs, simplifying
event management, student tracking, and parent-teacher communication.

## Deployment Options

Registry offers flexible deployment options to meet your organization's needs:

### 🏠 Self-Hosted (Recommended)

Deploy Registry on your own infrastructure for complete control:

**Benefits:**
- **Data Ownership**: Complete control over your organization's data
- **Customization**: Unlimited ability to modify workflows and features
- **Cost Effective**: No monthly fees, only infrastructure costs
- **Security**: Deploy in your secure environment with custom security policies
- **Integration**: Easy integration with existing systems and databases
- **Compliance**: Meet enterprise security and compliance requirements

**Quick Start:**

```bash
# Clone the repository
git clone https://github.com/perigrin/Registry.git
cd Registry

# Build and run with Docker
docker build -t registry .
docker run -p 3000:3000 registry

# Or use Docker Compose for full stack
docker-compose up

# Registry will be available at http://localhost:3000
```

### ☁️ Hosted Solution

For organizations that prefer a managed solution:

**Benefits:**
- **Worry-Free**: Fully managed hosting, maintenance, and updates
- **Quick Setup**: Get started in minutes with 30-day free trial
- **24/7 Support**: Email support and 99.9% uptime SLA
- **Automatic Backups**: Daily backups and disaster recovery
- **SSL & Security**: Enterprise-grade security included

**Pricing:** $200/month with 30-day free trial

[Start Free Trial](https://registry-demo.onrender.com) • [View Documentation](DEPLOYMENT.md)

### Understanding Registry

To better understand the system:
1. Read our [mission and vision](docs/MISSION.md)
2. Review our [user personas](docs/personas/)
3. Explore our [architectural documentation](docs/architecture/)

### Development

For developers interested in contributing:
1. Review [CONTRIBUTING.md](CONTRIBUTING.md) for core concepts
2. Check out our workflow examples in `workflows/`
3. Examine our schema definitions in `schemas/`
4. Look through our templates in `templates/`

### Production Deployment

Registry is production-ready with the following features implemented:

#### Security Features
- **Input Validation**: Comprehensive validation for all user inputs
- **SQL Injection Protection**: Parameterized queries throughout the application
- **XSS Prevention**: All user content properly escaped and sanitized
- **Authentication**: Role-based access control (admin, staff, instructor, parent)
- **Session Security**: Secure session management with proper timeouts

#### Performance Optimizations
- **Database Indexing**: Optimized indexes for frequently queried data
- **Query Optimization**: Efficient database queries for dashboard and reporting
- **Async Processing**: Background job processing with Minion for heavy operations
- **Caching**: Strategic caching for workflow and template data

#### Monitoring & Reliability
- **Error Handling**: Comprehensive error handling with user-friendly messages
- **Logging**: Detailed logging for debugging and monitoring
- **Health Checks**: Database connectivity and system health monitoring
- **Graceful Degradation**: System continues to function during partial failures

#### Payment Processing
- **Stripe Integration**: Secure payment processing with PCI compliance
- **Transaction Logging**: Complete audit trail for all financial transactions
- **Refund Support**: Built-in refund and partial payment capabilities
- **Multi-tier Pricing**: Flexible pricing plans per program

#### Communication System
- **Automated Notifications**: Email notifications for enrollment, waitlist, and payments
- **Bulk Messaging**: Administrative messaging to parents and staff
- **Message Templates**: Customizable email templates for different scenarios
- **Delivery Tracking**: Message delivery status and read receipts

#### Data Management
- **Multi-tenant Architecture**: Schema-based isolation for different organizations
- **Data Export**: Export capabilities for enrollment and financial data
- **Backup Support**: Database migration system with Sqitch for reliable deployments
- **GDPR Compliance**: User data management and deletion capabilities

#### User Experience
- **Mobile Responsive**: Full mobile experience for parents and staff
- **Accessibility**: WCAG 2.1 compliant user interface
- **Progressive Enhancement**: Works without JavaScript for core functionality
- **Loading States**: Interactive feedback during form submissions and data loading

#### Testing Coverage
- **Unit Tests**: Comprehensive DAO and business logic testing
- **Integration Tests**: End-to-end workflow testing
- **Security Tests**: Input validation and injection attack prevention
- **User Journey Tests**: Complete user story validation from registration to completion

#### Production Checklist
- [ ] Set environment variables: `DATABASE_URL`, `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`
- [ ] Configure email delivery: `SMTP_HOST`, `SMTP_USER`, `SMTP_PASS`
- [ ] Set up SSL certificates for HTTPS
- [ ] Configure backup strategy for PostgreSQL database
- [ ] Set up monitoring and alerting for application health
- [ ] Review and customize email templates in `templates/`
- [ ] Configure domain and DNS settings
- [ ] Set up log rotation and retention policies

## Copyright & License

This software is copyright (c) 2024 by Tamarou LLC.

This is free software; you can redistribute it and/or modify it under the same
terms as the Perl 5 programming language system itself.
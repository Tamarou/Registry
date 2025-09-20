# Manual Test Plan: Drop and Transfer Workflows

## Overview
This document outlines manual testing procedures for the drop and transfer enrollment workflows implemented in the Registry application.

## Test Prerequisites

### Database Setup
1. Start PostgreSQL service
2. Create development database: `createdb registry`
3. Deploy schema: `carton exec sqitch deploy`
4. Import workflows: `carton exec ./registry workflow import registry`
5. Import templates: `carton exec ./registry template import registry`

### Server Setup
1. Set `DB_URL` environment variable (if needed)
2. Start server: `carton exec morbo ./registry`

## Test Scenarios

### 1. Drop Enrollment Workflow

#### 1.1 Parent Drop Request (Before Session Starts)
**Scenario**: Parent requests to drop child enrollment before session begins
**Expected**: Immediate drop without admin approval

**Steps**:
1. Login as parent with active enrollment
2. Navigate to Parent Dashboard
3. Locate child enrollment
4. Click "Drop" button
5. Fill in drop modal:
   - Reason: "Schedule conflict"
   - Refund requested: Yes/No
6. Submit drop request

**Expected Results**:
- Enrollment status changes to 'cancelled'
- Drop reason recorded
- Refund status set appropriately
- Child removed from parent dashboard
- Waitlist processing triggered (if applicable)

#### 1.2 Parent Drop Request (After Session Starts)
**Scenario**: Parent requests to drop child enrollment after session has begun
**Expected**: Admin approval required

**Steps**:
1. Login as parent with active enrollment in started session
2. Navigate to Parent Dashboard
3. Click "Drop" button for enrollment
4. Fill in drop modal with reason and refund request
5. Submit request

**Expected Results**:
- Drop request created with 'pending' status
- Parent sees confirmation message
- Enrollment remains 'active' until admin approval
- Admin notification created

#### 1.3 Admin Drop Request Processing
**Scenario**: Admin processes pending drop requests
**Expected**: Admin can approve/deny with notes

**Steps**:
1. Login as admin
2. Navigate to Admin Dashboard
3. View "Pending Drop Requests" section
4. Click approve/deny on drop request
5. Add admin notes
6. Submit decision

**Expected Results**:
- Drop request status updated ('approved'/'denied')
- If approved: enrollment cancelled, refund processed
- If denied: enrollment remains active
- Parent notification sent
- Admin notes recorded

### 2. Transfer Enrollment Workflow

#### 2.1 Parent Transfer Request
**Scenario**: Parent requests to transfer child to different session
**Expected**: Admin approval always required

**Steps**:
1. Login as parent with active enrollment
2. Navigate to Parent Dashboard
3. Click "Transfer" button for enrollment
4. In transfer modal:
   - Select target session from dropdown
   - Enter reason for transfer
5. Submit transfer request

**Expected Results**:
- Transfer request created with 'pending' status
- Enrollment transfer_status set to 'requested'
- Parent sees confirmation message
- Admin notification created

#### 2.2 Transfer Validation
**Scenario**: System validates transfer requests
**Expected**: Proper validation for business rules

**Test Cases**:
- **Target session full**: Should reject with "Target session is full" error
- **Target session not found**: Should reject with "Target session not found" error
- **Valid transfer**: Should create transfer request successfully

**Steps**:
1. Attempt transfer to session at capacity → Should fail
2. Attempt transfer to non-existent session → Should fail
3. Attempt transfer to valid session with space → Should succeed

#### 2.3 Admin Transfer Request Processing
**Scenario**: Admin processes pending transfer requests
**Expected**: Admin can approve/deny with automatic enrollment updates

**Steps**:
1. Login as admin
2. Navigate to Admin Dashboard
3. View "Pending Transfer Requests" section
4. Review transfer details (from/to sessions, child info, reason)
5. Click approve/deny
6. Add admin notes
7. Submit decision

**Expected Results**:
- Transfer request status updated
- If approved:
  - Enrollment moved to target session
  - transfer_status set to 'completed'
  - Original session spot freed (waitlist processing)
- If denied:
  - Enrollment remains in original session
  - transfer_status reset to 'none'
- Parent notification sent

### 3. User Interface Testing

#### 3.1 Parent Dashboard
**Components to Test**:
- Drop button functionality
- Transfer button functionality
- Modal forms (validation, submission)
- Loading states
- Error handling
- Success messages

#### 3.2 Admin Dashboard
**Components to Test**:
- Pending requests display
- Request urgency indicators (today/recent/old)
- Approve/deny modals
- Admin notes functionality
- Request filtering
- Real-time updates

### 4. Integration Testing

#### 4.1 Email Notifications
**Verify**:
- Parent receives confirmation of request submission
- Admin receives notification of new requests
- Parent receives notification of admin decision

#### 4.2 Waitlist Processing
**Verify**:
- When enrollment dropped, waitlist automatically processes
- When transfer approved, both sessions process waitlists appropriately

#### 4.3 Payment Integration
**Verify**:
- Drop requests with refunds trigger payment processing
- Transfer requests handle payment adjustments correctly

### 5. Edge Cases

#### 5.1 Multiple Concurrent Requests
- Multiple parents requesting transfers to same limited session
- Admin processing requests while new ones are submitted
- Race conditions in capacity checking

#### 5.2 Data Consistency
- Partial failures in transfer process
- Database transaction rollbacks
- Orphaned transfer/drop requests

#### 5.3 User Experience
- Clear error messages
- Intuitive workflows
- Mobile responsiveness
- Accessibility compliance

## Test Data Requirements

### Users
- Parent user with multiple child enrollments
- Admin user with full permissions
- Teacher user (verify no access to drop/transfer)

### Sessions
- Session with capacity=1 (for testing full session logic)
- Session with current date (for testing started session logic)
- Session in future (for testing before-start logic)
- Sessions with waitlists

### Enrollments
- Active enrollments in various sessions
- Enrollments with existing transfer requests
- Enrollments in different states

## Success Criteria

✅ All drop workflows function correctly
✅ All transfer workflows function correctly
✅ Proper admin approval processes
✅ Correct business rule validation
✅ UI components work as expected
✅ Database consistency maintained
✅ Error handling works properly
✅ Notifications sent appropriately

## Known Issues to Verify Fixed

1. ✅ Capacity validation for transfers
2. ✅ Transfer status helper methods
3. ✅ Database constraint violations
4. ✅ Duplicate key errors in tests
5. ✅ Object lifecycle issues in enrollment creation

---

## Notes for Perigrin

This test plan provides comprehensive coverage of the drop and transfer functionality. The automated tests already verify the core business logic, so manual testing should focus on:

1. **User Experience**: Ensure the UI flows are intuitive and error-free
2. **Integration Points**: Verify notifications, waitlist processing, and payment integration
3. **Edge Cases**: Test scenarios that are difficult to automate
4. **Cross-browser Compatibility**: Test in different browsers/devices
5. **Performance**: Ensure acceptable response times under load

The implementation is now complete and all automated tests pass. The manual testing will verify the end-to-end user experience works as expected.
// Student Attendance Row Component
class StudentAttendanceRow extends HTMLElement {
    constructor() {
        super();
        this.attachShadow({ mode: 'open' });
    }

    static get observedAttributes() {
        return ['student-id', 'student-name', 'student-grade', 'family-name', 'status'];
    }

    connectedCallback() {
        this.render();
        this.setupEventListeners();
    }

    attributeChangedCallback(name, oldValue, newValue) {
        if (oldValue !== newValue) {
            this.render();
        }
    }

    get studentId() {
        return this.getAttribute('student-id');
    }

    get studentName() {
        return this.getAttribute('student-name');
    }

    get studentGrade() {
        return this.getAttribute('student-grade') || 'N/A';
    }

    get familyName() {
        return this.getAttribute('family-name');
    }

    get status() {
        return this.getAttribute('status');
    }

    set status(value) {
        this.setAttribute('status', value);
    }

    render() {
        this.shadowRoot.innerHTML = `
            <style>
                :host {
                    display: block;
                    border-bottom: 1px solid #eee;
                    background: white;
                }

                :host(:last-child) {
                    border-bottom: none;
                }

                .student-item {
                    display: flex;
                    align-items: center;
                    justify-content: space-between;
                    padding: 15px;
                }

                .student-info {
                    flex: 1;
                }

                .student-name {
                    font-weight: bold;
                    font-size: 16px;
                    margin-bottom: 5px;
                    color: #333;
                }

                .student-details {
                    font-size: 14px;
                    color: #666;
                }

                .attendance-buttons {
                    display: flex;
                    gap: 10px;
                }

                .attendance-btn {
                    padding: 10px 20px;
                    border: 2px solid;
                    border-radius: 25px;
                    background: white;
                    cursor: pointer;
                    font-size: 14px;
                    font-weight: bold;
                    min-width: 80px;
                    text-align: center;
                    transition: all 0.2s ease;
                }

                .attendance-btn:hover {
                    transform: scale(1.05);
                }

                .attendance-btn.present {
                    border-color: #28a745;
                    color: #28a745;
                }

                .attendance-btn.present.active {
                    background: #28a745;
                    color: white;
                }

                .attendance-btn.absent {
                    border-color: #dc3545;
                    color: #dc3545;
                }

                .attendance-btn.absent.active {
                    background: #dc3545;
                    color: white;
                }

                .attendance-btn:focus {
                    outline: 2px solid #007bff;
                    outline-offset: 2px;
                }
            </style>
            
            <div class="student-item">
                <div class="student-info">
                    <div class="student-name">${this.studentName}</div>
                    <div class="student-details">
                        Grade: ${this.studentGrade} | Family: ${this.familyName}
                    </div>
                </div>
                <div class="attendance-buttons">
                    <button 
                        type="button" 
                        class="attendance-btn present ${this.status === 'present' ? 'active' : ''}"
                        data-status="present"
                        aria-label="Mark ${this.studentName} as present">
                        Present
                    </button>
                    <button 
                        type="button" 
                        class="attendance-btn absent ${this.status === 'absent' ? 'active' : ''}"
                        data-status="absent"
                        aria-label="Mark ${this.studentName} as absent">
                        Absent
                    </button>
                </div>
            </div>
        `;
    }

    setupEventListeners() {
        const buttons = this.shadowRoot.querySelectorAll('.attendance-btn');
        buttons.forEach(btn => {
            btn.addEventListener('click', (e) => {
                const status = e.target.dataset.status;
                this.setAttendanceStatus(status);
                
                // Dispatch custom event for the form to listen to
                this.dispatchEvent(new CustomEvent('attendance-changed', {
                    detail: {
                        studentId: this.studentId,
                        status: status,
                        studentName: this.studentName
                    },
                    bubbles: true
                }));
            });
        });
    }

    setAttendanceStatus(status) {
        // Remove active class from all buttons
        const buttons = this.shadowRoot.querySelectorAll('.attendance-btn');
        buttons.forEach(btn => btn.classList.remove('active'));
        
        // Add active class to selected button
        const selectedBtn = this.shadowRoot.querySelector(`[data-status="${status}"]`);
        if (selectedBtn) {
            selectedBtn.classList.add('active');
        }
        
        // Update attribute
        this.status = status;
    }
}

// Attendance Form Component
class AttendanceForm extends HTMLElement {
    constructor() {
        super();
        this.attachShadow({ mode: 'open' });
        this.attendanceData = {};
        this.totalStudents = 0;
    }

    static get observedAttributes() {
        return ['event-id', 'total-students'];
    }

    connectedCallback() {
        this.totalStudents = parseInt(this.getAttribute('total-students')) || 0;
        this.render();
        this.setupEventListeners();
        this.updateCounts();
    }

    get eventId() {
        return this.getAttribute('event-id');
    }

    render() {
        this.shadowRoot.innerHTML = `
            <style>
                :host {
                    display: block;
                }

                .submit-section {
                    padding: 20px;
                    background: #f8f9fa;
                    margin-top: 20px;
                    border-radius: 6px;
                    text-align: center;
                }

                .summary {
                    margin-bottom: 15px;
                    font-size: 16px;
                }

                .count {
                    font-weight: bold;
                    color: #007bff;
                }

                .count.present { color: #28a745; }
                .count.absent { color: #dc3545; }
                .count.unmarked { color: #6c757d; }

                .btn {
                    display: inline-block;
                    padding: 12px 24px;
                    border-radius: 6px;
                    border: none;
                    font-size: 16px;
                    cursor: pointer;
                    margin: 5px;
                    text-align: center;
                    text-decoration: none;
                    transition: all 0.2s ease;
                }

                .btn:disabled {
                    opacity: 0.6;
                    cursor: not-allowed;
                }

                .btn-success {
                    background: #28a745;
                    color: white;
                }

                .btn-success:hover:not(:disabled) {
                    background: #1e7e34;
                }

                .btn-secondary {
                    background: #6c757d;
                    color: white;
                }

                .btn-secondary:hover {
                    background: #545b62;
                }

                .loading {
                    display: none;
                    margin: 10px 0;
                }

                .spinner {
                    display: inline-block;
                    width: 20px;
                    height: 20px;
                    border: 2px solid #f3f3f3;
                    border-top: 2px solid #007bff;
                    border-radius: 50%;
                    animation: spin 1s linear infinite;
                }

                @keyframes spin {
                    0% { transform: rotate(0deg); }
                    100% { transform: rotate(360deg); }
                }

                .message-area {
                    margin-top: 15px;
                }

                .alert {
                    padding: 15px;
                    border-radius: 6px;
                    margin: 10px 0;
                }

                .alert-success {
                    background: #d4edda;
                    color: #155724;
                    border: 1px solid #c3e6cb;
                }

                .alert-error {
                    background: #f8d7da;
                    color: #721c24;
                    border: 1px solid #f5c6cb;
                }

                .progress-bar {
                    width: 100%;
                    height: 8px;
                    background: #e9ecef;
                    border-radius: 4px;
                    overflow: hidden;
                    margin: 10px 0;
                }

                .progress-fill {
                    height: 100%;
                    background: linear-gradient(90deg, #28a745, #20c997);
                    transition: width 0.3s ease;
                }
            </style>
            
            <div class="submit-section">
                <div class="summary">
                    <span class="count present" id="present-count">0</span> Present, 
                    <span class="count absent" id="absent-count">0</span> Absent, 
                    <span class="count unmarked" id="unmarked-count">${this.totalStudents}</span> Unmarked
                </div>
                
                <div class="progress-bar">
                    <div class="progress-fill" id="progress-fill" style="width: 0%"></div>
                </div>
                
                <div class="loading" id="loading">
                    <div class="spinner"></div>
                    <div>Saving attendance...</div>
                </div>
                
                <button type="button" class="btn btn-success" id="submit-btn" disabled>
                    Save Attendance
                </button>
                
                <a href="/teacher/" class="btn btn-secondary">
                    Back to Dashboard
                </a>
                
                <div class="message-area" id="message-area"></div>
            </div>
        `;
    }

    setupEventListeners() {
        // Listen for attendance changes from student rows
        this.addEventListener('attendance-changed', (e) => {
            const { studentId, status } = e.detail;
            this.attendanceData[studentId] = status;
            this.updateCounts();
        });

        // Handle form submission
        const submitBtn = this.shadowRoot.getElementById('submit-btn');
        submitBtn.addEventListener('click', () => {
            this.submitAttendance();
        });
    }

    updateCounts() {
        let present = 0, absent = 0;
        
        Object.values(this.attendanceData).forEach(status => {
            if (status === 'present') present++;
            if (status === 'absent') absent++;
        });
        
        const unmarked = this.totalStudents - present - absent;
        const progress = this.totalStudents > 0 ? ((present + absent) / this.totalStudents) * 100 : 0;
        
        // Update counts
        this.shadowRoot.getElementById('present-count').textContent = present;
        this.shadowRoot.getElementById('absent-count').textContent = absent;
        this.shadowRoot.getElementById('unmarked-count').textContent = unmarked;
        
        // Update progress bar
        this.shadowRoot.getElementById('progress-fill').style.width = `${progress}%`;
        
        // Enable submit button if all students marked
        const submitBtn = this.shadowRoot.getElementById('submit-btn');
        submitBtn.disabled = unmarked > 0;
        
        if (unmarked === 0) {
            submitBtn.textContent = '✓ Save Attendance (Complete)';
        } else {
            submitBtn.textContent = `Save Attendance (${unmarked} remaining)`;
        }
    }

    async submitAttendance() {
        const loading = this.shadowRoot.getElementById('loading');
        const messageArea = this.shadowRoot.getElementById('message-area');
        const submitBtn = this.shadowRoot.getElementById('submit-btn');
        
        loading.style.display = 'block';
        submitBtn.disabled = true;
        messageArea.innerHTML = '';
        
        try {
            const response = await fetch(`/teacher/attendance/${this.eventId}`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify(this.attendanceData)
            });
            
            const data = await response.json();
            
            if (data.success) {
                messageArea.innerHTML = `
                    <div class="alert alert-success">
                        <strong>Success!</strong> Attendance saved for ${data.total_marked} students.
                    </div>
                `;
                submitBtn.textContent = 'Attendance Saved ✓';
                submitBtn.className = 'btn btn-secondary';
                
                // Dispatch success event
                this.dispatchEvent(new CustomEvent('attendance-saved', {
                    detail: { 
                        totalMarked: data.total_marked,
                        attendanceData: this.attendanceData
                    },
                    bubbles: true
                }));
            } else {
                throw new Error(data.error || 'Failed to save attendance');
            }
        } catch (error) {
            messageArea.innerHTML = `
                <div class="alert alert-error">
                    <strong>Error:</strong> ${error.message}
                </div>
            `;
            submitBtn.disabled = false;
        } finally {
            loading.style.display = 'none';
        }
    }

    // Public method to set initial attendance data
    setInitialAttendance(attendanceData) {
        this.attendanceData = { ...attendanceData };
        this.updateCounts();
    }
}

// Register the custom elements
customElements.define('student-attendance-row', StudentAttendanceRow);
customElements.define('attendance-form', AttendanceForm);

// Export for module systems
if (typeof module !== 'undefined' && module.exports) {
    module.exports = { StudentAttendanceRow, AttendanceForm };
}
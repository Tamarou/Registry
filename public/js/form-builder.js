// form-builder.js
class FormBuilder extends HTMLElement {
    constructor() {
        super();
        this.attachShadow({ mode: 'open' });
        this._schema = null;
        this._data = {};
        this._errors = [];
    }
    
    static get observedAttributes() {
        return ['outcome-definition-url', 'form-data', 'validation-errors'];
    }
    
    attributeChangedCallback(name, oldValue, newValue) {
        if (oldValue !== newValue) {
            this.render();
        }
    }
    
    connectedCallback() {
        this.render();
    }
    
    get schemaUrl() {
        return this.getAttribute('outcome-definition-url');
    }
    
    get formData() {
        try {
            return this.getAttribute('form-data') ? 
                JSON.parse(this.getAttribute('form-data')) : {};
        } catch (e) {
            console.error('Invalid form data JSON:', e);
            return {};
        }
    }
    
    get validationErrors() {
        try {
            return this.getAttribute('validation-errors') ? 
                JSON.parse(this.getAttribute('validation-errors')) : [];
        } catch (e) {
            console.error('Invalid validation errors JSON:', e);
            return [];
        }
    }
    
    async render() {
        if (!this.schemaUrl) return;
        
        try {
            if (!this._schema) {
                const response = await fetch(this.schemaUrl);
                this._schema = await response.json();
            }
            
            this._data = this.formData;
            this._errors = this.validationErrors;
            
            this.shadowRoot.innerHTML = this._buildStyles() + this._buildForm();
            this._setupEventListeners();
        } catch (error) {
            console.error('Error loading schema:', error);
            this.shadowRoot.innerHTML = `<div class="error">Error loading form schema</div>`;
        }
    }
    
    _buildStyles() {
        return `
            <style>
                :host {
                    display: block;
                    font-family: system-ui, sans-serif;
                }
                .form-container {
                    max-width: 800px;
                    margin: 0 auto;
                }
                .form-field {
                    margin-bottom: 1.5rem;
                }
                label {
                    display: block;
                    margin-bottom: 0.5rem;
                    font-weight: 500;
                }
                input, select, textarea {
                    width: 100%;
                    padding: 0.5rem;
                    border: 1px solid #ddd;
                    border-radius: 4px;
                    font-size: 1rem;
                }
                .field-error {
                    color: #d32f2f;
                    font-size: 0.875rem;
                    margin-top: 0.25rem;
                }
                .has-error input, .has-error select, .has-error textarea {
                    border-color: #d32f2f;
                }
                .error-summary {
                    background-color: #ffebee;
                    color: #d32f2f;
                    padding: 1rem;
                    margin-bottom: 1.5rem;
                    border-radius: 4px;
                }
                .error-summary h3 {
                    margin-top: 0;
                    margin-bottom: 0.5rem;
                }
                .error-summary ul {
                    margin-bottom: 0;
                }
                button[type="submit"] {
                    background-color: #1976d2;
                    color: white;
                    border: none;
                    padding: 0.75rem 1.5rem;
                    font-size: 1rem;
                    border-radius: 4px;
                    cursor: pointer;
                }
                button[type="submit"]:hover {
                    background-color: #1565c0;
                }
            </style>
        `;
    }
    
    _buildForm() {
        if (!this._schema) return '<div>Loading schema...</div>';
        
        let html = `<div class="form-container">`;
        
        // Add error summary if any
        if (this._errors.length > 0) {
            html += `<div class="error-summary">
                <h3>Please correct the following errors:</h3>
                <ul>
                    ${this._errors.map(err => `<li data-field="${err.field}">${err.message}</li>`).join('')}
                </ul>
            </div>`;
        }
        
        // Start form
        html += `<form method="POST">`;
        
        // Build fields based on schema
        if (this._schema.fields && Array.isArray(this._schema.fields)) {
            for (const field of this._schema.fields) {
                const fieldValue = this._data[field.id] || '';
                const hasError = this._errors.some(err => err.field === field.id);
                
                html += `<div class="form-field ${hasError ? 'has-error' : ''}">
                    <label for="${field.id}">${field.label || field.id}${field.required ? ' *' : ''}</label>
                    ${this._renderField(field, fieldValue)}
                    ${hasError ? `<div class="field-error">${this._errors.find(e => e.field === field.id).message}</div>` : ''}
                </div>`;
            }
        }
        
        // Add submit button
        html += `<button type="submit">Continue</button>`;
        
        html += `</form></div>`;
        return html;
    }
    
    _renderField(field, value) {
        // Special cases that can't be handled with simple input type substitution
        switch (field.type) {
            case 'textarea':
                return `<textarea name="${field.id}" id="${field.id}" ${field.required ? 'required' : ''}>${this._escape(value)}</textarea>`;
                
            case 'select':
                return `<select name="${field.id}" id="${field.id}" ${field.required ? 'required' : ''}>
                    <option value="">Select...</option>
                    ${field.options.map(opt => {
                        if (typeof opt === 'object') {
                            return `<option value="${opt.value}" ${value === opt.value ? 'selected' : ''}>${opt.label}</option>`;
                        } else {
                            return `<option value="${opt}" ${value === opt ? 'selected' : ''}>${opt}</option>`;
                        }
                    }).join('')}
                </select>`;
                
            case 'radio':
                return field.options.map(opt => {
                    if (typeof opt === 'object') {
                        return `<div class="radio-option">
                            <input type="radio" name="${field.id}" id="${field.id}_${opt.value}" value="${opt.value}" ${value === opt.value ? 'checked' : ''}>
                            <label for="${field.id}_${opt.value}">${opt.label}</label>
                        </div>`;
                    } else {
                        return `<div class="radio-option">
                            <input type="radio" name="${field.id}" id="${field.id}_${opt}" value="${opt}" ${value === opt ? 'checked' : ''}>
                            <label for="${field.id}_${opt}">${opt}</label>
                        </div>`;
                    }
                }).join('');
                
            case 'checkbox':
                return `<input type="checkbox" name="${field.id}" id="${field.id}" ${value ? 'checked' : ''} value="1">`;
                
            default:
                // Use the field type directly as the input type
                return `<input type="${field.type}" name="${field.id}" id="${field.id}" value="${this._escape(value)}" ${field.required ? 'required' : ''} ${field.min ? `min="${field.min}"` : ''} ${field.max ? `max="${field.max}"` : ''}>`;
        }
    }
    
    _escape(str) {
        if (str === null || str === undefined) return '';
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
    }
    
    async _validateForm(formData) {
        try {
            const response = await fetch('/outcome/validate', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({
                    outcome_definition_id: this._schema.id,
                    data: Object.fromEntries(formData)
                })
            });
            
            const result = await response.json();
            
            if (!result.valid) {
                // Update errors display
                this._errors = result.errors;
                this.render();
                return false;
            }
            
            return true;
        } catch (error) {
            console.error('Validation error:', error);
            return true; // Fall back to server-side validation
        }
    }
    
    _setupEventListeners() {
        const form = this.shadowRoot.querySelector('form');
        if (form) {
            form.addEventListener('submit', async (e) => {
                e.preventDefault();
                
                const formData = new FormData(form);
                
                // Validate form data using the API
                const isValid = await this._validateForm(formData);
                if (isValid) {
                    // Submit the form to the parent context
                    const parentForm = document.createElement('form');
                    parentForm.method = 'POST';
                    parentForm.action = window.location.href;
                    
                    for (const [name, value] of formData.entries()) {
                        const input = document.createElement('input');
                        input.type = 'hidden';
                        input.name = name;
                        input.value = value;
                        parentForm.appendChild(input);
                    }
                    
                    document.body.appendChild(parentForm);
                    parentForm.submit();
                }
            });
        }
    }
}

customElements.define('form-builder', FormBuilder);

/**
 * Workflow Progress Web Component
 * 
 * A reusable breadcrumb-style progress indicator for Registry workflows.
 * Supports backward navigation and integrates with HTMX.
 */
class WorkflowProgress extends HTMLElement {
    constructor() {
        super();
        this.attachShadow({ mode: 'open' });
    }

    connectedCallback() {
        this.render();
        this.setupEventListeners();
    }

    static get observedAttributes() {
        return ['data-current-step', 'data-total-steps', 'data-step-names', 'data-step-urls', 'data-completed-steps'];
    }

    attributeChangedCallback() {
        if (this.shadowRoot) {
            this.render();
        }
    }

    get currentStep() {
        return parseInt(this.getAttribute('data-current-step') || '1');
    }

    get totalSteps() {
        return parseInt(this.getAttribute('data-total-steps') || '1');
    }

    get stepNames() {
        const names = this.getAttribute('data-step-names');
        return names ? names.split(',').map(name => name.trim()) : [];
    }

    get stepUrls() {
        const urls = this.getAttribute('data-step-urls');
        return urls ? urls.split(',').map(url => url.trim()) : [];
    }

    get completedSteps() {
        const completed = this.getAttribute('data-completed-steps');
        return completed ? completed.split(',').map(step => parseInt(step.trim())) : [];
    }

    render() {
        const styles = `
            <style>
                :host {
                    display: block;
                    margin: 1rem 0;
                    font-family: inherit;
                }

                .progress-container {
                    display: flex;
                    align-items: center;
                    gap: 0.5rem;
                    padding: 1rem;
                    background: #f8f9fa;
                    border-radius: 0.5rem;
                    border: 1px solid #e9ecef;
                    overflow-x: auto;
                }

                .step {
                    display: flex;
                    align-items: center;
                    gap: 0.5rem;
                    flex-shrink: 0;
                    padding: 0.5rem 0.75rem;
                    border-radius: 0.375rem;
                    transition: all 0.2s ease;
                    text-decoration: none;
                    color: inherit;
                    min-height: 2.5rem;
                }

                .step:focus {
                    outline: 2px solid #3b82f6;
                    outline-offset: 2px;
                }

                .step.completed {
                    background: #22c55e;
                    color: white;
                    cursor: pointer;
                }

                .step.completed:hover {
                    background: #16a34a;
                }

                .step.current {
                    background: #3b82f6;
                    color: white;
                    font-weight: 600;
                }

                .step.upcoming {
                    background: #e5e7eb;
                    color: #6b7280;
                    cursor: not-allowed;
                }

                .step-number {
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    width: 1.5rem;
                    height: 1.5rem;
                    border-radius: 50%;
                    background: rgba(255, 255, 255, 0.2);
                    font-size: 0.875rem;
                    font-weight: 600;
                }

                .step.completed .step-number {
                    background: rgba(255, 255, 255, 0.3);
                }

                .step.current .step-number {
                    background: rgba(255, 255, 255, 0.2);
                }

                .step.upcoming .step-number {
                    background: rgba(107, 114, 128, 0.1);
                }

                .step-name {
                    font-size: 0.875rem;
                    white-space: nowrap;
                }

                .separator {
                    width: 1rem;
                    height: 2px;
                    background: #d1d5db;
                    flex-shrink: 0;
                }

                .sr-only {
                    position: absolute;
                    width: 1px;
                    height: 1px;
                    padding: 0;
                    margin: -1px;
                    overflow: hidden;
                    clip: rect(0, 0, 0, 0);
                    white-space: nowrap;
                    border: 0;
                }

                @media (max-width: 640px) {
                    .progress-container {
                        padding: 0.75rem;
                        gap: 0.25rem;
                    }

                    .step {
                        padding: 0.375rem 0.5rem;
                    }

                    .step-name {
                        display: none;
                    }

                    .separator {
                        width: 0.5rem;
                    }
                }

                @media (max-width: 480px) {
                    .step-number {
                        width: 1.25rem;
                        height: 1.25rem;
                        font-size: 0.75rem;
                    }
                }
            </style>
        `;

        const steps = [];
        for (let i = 1; i <= this.totalSteps; i++) {
            const stepName = this.stepNames[i - 1] || `Step ${i}`;
            const stepUrl = this.stepUrls[i - 1] || '';
            const isCompleted = this.completedSteps.includes(i) || i < this.currentStep;
            const isCurrent = i === this.currentStep;
            const isUpcoming = i > this.currentStep;

            let stepClass = '';
            let tabIndex = '-1';
            let ariaLabel = '';
            
            if (isCompleted) {
                stepClass = 'completed';
                tabIndex = '0';
                ariaLabel = `Go to completed ${stepName}`;
            } else if (isCurrent) {
                stepClass = 'current';
                ariaLabel = `Current step: ${stepName}`;
            } else {
                stepClass = 'upcoming';
                ariaLabel = `Upcoming step: ${stepName}`;
            }

            const stepElement = `
                <${isCompleted && stepUrl ? 'a' : 'div'} 
                    class="step ${stepClass}" 
                    ${isCompleted && stepUrl ? `href="${stepUrl}"` : ''}
                    ${isCompleted && stepUrl ? `hx-get="${stepUrl}"` : ''}
                    ${isCompleted && stepUrl ? 'hx-target="body"' : ''}
                    ${isCompleted && stepUrl ? 'hx-push-url="true"' : ''}
                    tabindex="${tabIndex}"
                    role="${isCompleted && stepUrl ? 'link' : 'text'}"
                    aria-label="${ariaLabel}"
                    data-step="${i}">
                    <span class="step-number" aria-hidden="true">${i}</span>
                    <span class="step-name">${stepName}</span>
                    <span class="sr-only">${ariaLabel}</span>
                </${isCompleted && stepUrl ? 'a' : 'div'}>
            `;

            steps.push(stepElement);

            // Add separator except after last step
            if (i < this.totalSteps) {
                steps.push('<div class="separator" aria-hidden="true"></div>');
            }
        }

        this.shadowRoot.innerHTML = `
            ${styles}
            <nav class="progress-container" role="navigation" aria-label="Workflow progress">
                ${steps.join('')}
            </nav>
        `;
    }

    setupEventListeners() {
        // Handle keyboard navigation
        this.shadowRoot.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                const target = e.target;
                if (target.classList.contains('completed') && target.href) {
                    e.preventDefault();
                    if (typeof htmx !== 'undefined') {
                        htmx.ajax('GET', target.href, { target: 'body', swap: 'outerHTML' });
                    } else {
                        window.location.href = target.href;
                    }
                }
            }
        });

        // Handle click events for better HTMX integration
        this.shadowRoot.addEventListener('click', (e) => {
            const target = e.target.closest('.step');
            if (target && target.classList.contains('completed') && target.href) {
                e.preventDefault();
                
                // Dispatch custom event for analytics/tracking
                this.dispatchEvent(new CustomEvent('workflow-navigation', {
                    detail: {
                        fromStep: this.currentStep,
                        toStep: parseInt(target.dataset.step),
                        stepName: target.querySelector('.step-name').textContent
                    },
                    bubbles: true
                }));

                // Use HTMX if available, otherwise fallback to regular navigation
                if (typeof htmx !== 'undefined') {
                    htmx.ajax('GET', target.href, { 
                        target: 'body', 
                        swap: 'outerHTML',
                        headers: {
                            'HX-Request': 'true',
                            'HX-Current-URL': window.location.href
                        }
                    });
                } else {
                    window.location.href = target.href;
                }
            }
        });
    }

    // Public API methods
    updateProgress(currentStep, completedSteps = []) {
        this.setAttribute('data-current-step', currentStep.toString());
        this.setAttribute('data-completed-steps', completedSteps.join(','));
    }

    setStepUrls(urls) {
        this.setAttribute('data-step-urls', urls.join(','));
    }

    setStepNames(names) {
        this.setAttribute('data-step-names', names.join(','));
    }
}

// Register the custom element
customElements.define('workflow-progress', WorkflowProgress);

// Export for potential module usage
if (typeof module !== 'undefined' && module.exports) {
    module.exports = WorkflowProgress;
}
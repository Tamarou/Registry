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
                    gap: 0.75rem;
                    padding: 1.5rem;
                    background: rgba(255, 255, 255, 0.85);
                    backdrop-filter: blur(10px);
                    border-radius: 1rem;
                    border: 2px solid rgba(255, 0, 255, 0.3);
                    overflow-x: auto;
                    box-shadow: 0 5px 15px rgba(0, 0, 0, 0.1);
                }

                @media (prefers-color-scheme: dark) {
                    .progress-container {
                        background: rgba(26, 8, 41, 0.85);
                        border-color: rgba(255, 0, 255, 0.5);
                    }
                }

                .step {
                    display: flex;
                    align-items: center;
                    gap: 0.5rem;
                    flex-shrink: 0;
                    padding: 0.75rem 1rem;
                    border-radius: 50px;
                    transition: all 0.3s ease;
                    text-decoration: none;
                    color: inherit;
                    min-height: 2.5rem;
                    font-weight: 600;
                }

                .step:focus {
                    outline: 2px solid #00ffff;
                    outline-offset: 2px;
                }

                .step.completed {
                    background: linear-gradient(135deg, #29a6a6 0%, #2abfbf 100%);
                    color: white;
                    cursor: pointer;
                    box-shadow: 0 3px 10px rgba(42, 191, 191, 0.3);
                }

                .step.completed:hover {
                    transform: translateY(-2px);
                    box-shadow: 0 5px 15px rgba(42, 191, 191, 0.5);
                }

                .step.current {
                    background: linear-gradient(135deg, #667eea 0%, #9d4edd 100%);
                    color: white;
                    font-weight: 700;
                    box-shadow: 0 5px 15px rgba(157, 78, 221, 0.4);
                    animation: pulse-glow 2s ease-in-out infinite;
                }

                @keyframes pulse-glow {
                    0%, 100% {
                        box-shadow: 0 5px 15px rgba(157, 78, 221, 0.4);
                    }
                    50% {
                        box-shadow: 0 5px 20px rgba(157, 78, 221, 0.6);
                    }
                }

                .step.upcoming {
                    background: rgba(157, 78, 221, 0.1);
                    color: #9d4edd;
                    cursor: not-allowed;
                    opacity: 0.6;
                }

                .step-number {
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    width: 1.75rem;
                    height: 1.75rem;
                    border-radius: 50%;
                    background: rgba(255, 255, 255, 0.25);
                    font-size: 0.875rem;
                    font-weight: 700;
                }

                .step.completed .step-number {
                    background: rgba(255, 255, 255, 0.3);
                }

                .step.current .step-number {
                    background: rgba(255, 255, 255, 0.3);
                }

                .step.upcoming .step-number {
                    background: rgba(157, 78, 221, 0.15);
                }

                .step-name {
                    font-size: 0.875rem;
                    white-space: nowrap;
                    letter-spacing: 0.5px;
                }

                .separator {
                    width: 1.5rem;
                    height: 3px;
                    background: linear-gradient(90deg, rgba(157, 78, 221, 0.3) 0%, rgba(0, 255, 255, 0.3) 100%);
                    flex-shrink: 0;
                    border-radius: 2px;
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
                        padding: 1rem;
                        gap: 0.5rem;
                    }

                    .step {
                        padding: 0.5rem 0.75rem;
                    }

                    .step-name {
                        display: none;
                    }

                    .separator {
                        width: 0.75rem;
                    }
                }

                @media (max-width: 480px) {
                    .step-number {
                        width: 1.5rem;
                        height: 1.5rem;
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
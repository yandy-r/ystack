# Agent Catalog

## Contents

- Agent Categories
- Selection Matrix
- Agent Selection Guidelines
- Common Orchestration Patterns

Complete reference of all available agents for orchestration.

## Agent Categories

### Code Discovery & Research

#### explore

**Best For**: Quick file/code searches, pattern finding, codebase exploration

**Capabilities**:

- Fast file pattern matching (e.g., "src/components/\*_/_.tsx")
- Keyword-based code searches
- Quick architecture questions
- Thoroughness levels: quick, medium, very thorough

**Example Use Cases**:

- "Find all API endpoints"
- "Locate authentication-related files"
- "Search for database query patterns"

**When to Use**: Need to quickly locate code without deep analysis

---

#### code-finder

**Best For**: Locating specific code implementations, functions, classes

**Capabilities**:

- Find specific functions, classes, methods
- Locate where variables are defined/used
- Discover related code segments
- Pattern-based code discovery

**Example Use Cases**:

- "Where is the User model defined?"
- "Find all usages of the payment processing function"
- "Locate the authentication middleware"

**When to Use**: Need to find specific code elements by name or pattern

---

#### codebase-research-analyst

**Best For**: Comprehensive codebase analysis, architecture understanding

**Capabilities**:

- Analyze architecture patterns
- Identify implementation conventions
- Map component relationships
- Research before implementing features

**Example Use Cases**:

- "How does authentication work in this codebase?"
- "Analyze the data layer architecture"
- "Research existing API patterns before adding endpoints"

**When to Use**: Need deep understanding before implementation or planning

---

### Frontend Development

#### frontend-ui-developer

**Best For**: UI components, pages, styling, React/frontend work

**Capabilities**:

- Create/modify React components
- Implement UI designs
- Update styling (Tailwind, CSS)
- Establish design systems
- Responsive design implementation

**Example Use Cases**:

- "Create a user dashboard page"
- "Add a new button variant to the design system"
- "Make the navigation mobile-friendly"

**When to Use**: Any frontend UI/component work

---

#### nextjs-ux-ui-expert

**Best For**: Next.js-specific UI/UX, performance optimization, accessibility

**Capabilities**:

- Next.js component architecture
- SSR/SSG optimization
- Performance tuning
- Accessibility implementation
- Theme systems and design patterns

**Example Use Cases**:

- "Create a data table with sorting/filtering in Next.js"
- "Optimize page load performance"
- "Implement dark mode theme system"

**When to Use**: Next.js projects requiring UX expertise or optimization

---

### Backend Development

#### nodejs-backend-architect

**Best For**: Node.js/TypeScript backend, APIs, microservices

**Capabilities**:

- Design microservices architecture
- Implement RESTful/GraphQL APIs
- Backend system design
- Authentication/authorization
- Database integration

**Example Use Cases**:

- "Design a scalable API for user management"
- "Implement authentication service"
- "Refactor backend for microservices"

**When to Use**: Node.js/TypeScript backend development or architecture

---

#### go-api-architect

**Best For**: Go REST APIs, microservices, API design

**Capabilities**:

- Design/implement Go REST APIs
- Microservice architecture
- Performance optimization
- Authentication/authorization
- API documentation

**Example Use Cases**:

- "Create a REST API for inventory management in Go"
- "Review Go API implementation"
- "Optimize concurrent request handling"

**When to Use**: Go API development or review

---

#### go-expert-architect

**Best For**: Advanced Go development, concurrency, systems programming

**Capabilities**:

- Idiomatic Go code
- Concurrent systems design
- Distributed systems
- Performance optimization
- Go best practices

**Example Use Cases**:

- "Build a concurrent data processing pipeline"
- "Review microservice architecture"
- "Optimize memory usage and GC"

**When to Use**: Complex Go systems or performance-critical work

---

### Database

#### db-modifier

**Best For**: Database schema changes, migrations, RLS policies

**Capabilities**:

- Create/alter tables
- Write migrations
- Modify RLS policies
- Create RPC functions
- Data updates

**Example Use Cases**:

- "Add a 'featured' column to the stories table"
- "Create an RPC function for user metrics"
- "Update all records to set default status"

**When to Use**: Any database schema or data modifications

---

#### sql-database-architect

**Best For**: Database design, query optimization, Turso/SQLite/SQL

**Capabilities**:

- Schema design
- Query optimization
- Migration strategies
- Data modeling
- Index strategies

**Example Use Cases**:

- "Optimize slow query on products table"
- "Design schema for user sessions"
- "Review migration scripts"

**When to Use**: Database architecture, design, or optimization

---

### Infrastructure & DevOps

#### terraform-architect

**Best For**: Infrastructure as code, cloud architecture

**Capabilities**:

- Design cloud architectures
- Write Terraform configurations
- Infrastructure best practices
- Multi-cloud strategies
- Module design

**Example Use Cases**:

- "Set up infrastructure for microservices"
- "Review VPC module for best practices"
- "Design auto-scaling infrastructure"

**When to Use**: Infrastructure design or Terraform work

---

#### cloudflare-architect

**Best For**: Cloudflare services, CDN, security, Workers

**Capabilities**:

- CDN configuration
- Workers implementation
- WAF/DDoS protection
- Zero Trust architecture
- Performance optimization

**Example Use Cases**:

- "Set up Cloudflare Workers for rate limiting"
- "Troubleshoot 520 errors"
- "Design Zero Trust access"

**When to Use**: Cloudflare-specific tasks

---

#### reverse-proxy-architect

**Best For**: nginx, HAProxy, Traefik configuration

**Capabilities**:

- Load balancing
- SSL/TLS termination
- Request routing
- Rate limiting
- WebSocket proxying

**Example Use Cases**:

- "Set up nginx for multi-backend proxying"
- "Fix nginx 502 errors in Kubernetes"
- "Configure Traefik with Let's Encrypt"

**When to Use**: Reverse proxy configuration or troubleshooting

---

#### ansible-automation-expert

**Best For**: Ansible playbooks, automation, configuration management

**Capabilities**:

- Playbook development
- Role creation
- Inventory management
- Network automation
- Infrastructure as code

**Example Use Cases**:

- "Create playbook for web server setup"
- "Troubleshoot SSH connection errors"
- "Design IaC solution with Ansible"

**When to Use**: Ansible automation tasks

---

#### systems-engineering-expert

**Best For**: System administration, macOS/Linux optimization, DevOps

**Capabilities**:

- Security hardening
- Performance tuning
- System architecture
- Shell scripting
- Cross-platform development

**Example Use Cases**:

- "Optimize Python application on Ubuntu"
- "Secure macOS development environment"
- "Design cross-platform dotfiles"

**When to Use**: System-level work, optimization, DevOps practices

---

### Documentation

#### documentation-writer

**Best For**: Feature docs, CLI docs, README files

**Capabilities**:

- Feature documentation
- CLI command documentation
- README creation/updates
- User guides
- Code documentation

**Example Use Cases**:

- "Document payment processing endpoint"
- "Document new CLI commands"
- "Create feature guide for authentication"

**When to Use**: General documentation needs

---

#### api-docs-expert

**Best For**: API documentation, OpenAPI specs, endpoint documentation

**Capabilities**:

- API design review
- OpenAPI/Swagger specs
- Endpoint documentation
- Request/response examples
- API best practices

**Example Use Cases**:

- "Document enrichment API endpoints"
- "Create OpenAPI specification"
- "Review API design patterns"

**When to Use**: API-specific documentation

---

#### library-docs-writer

**Best For**: Fetching and condensing external library documentation

**Capabilities**:

- Fetch latest library docs
- Compress into reference files
- Create quick-reference guides
- Single source of truth for dependencies

**Example Use Cases**:

- "Create reference doc for React Server Components"
- "Get latest Supabase RLS documentation"

**When to Use**: Need local copies of external library documentation

---

### Testing & Debugging

#### test-strategy-planner

**Best For**: Creating comprehensive test strategies and plans

**Capabilities**:

- Analyze code for test needs
- Create test strategy
- Plan unit/integration/e2e tests
- Identify critical paths
- Testing roadmap

**Example Use Cases**:

- "Create testing strategy for auth service"
- "Plan comprehensive testing for payment API"
- "Establish testing for untested codebase"

**When to Use**: Need test planning (not implementation)

---

#### root-cause-analyzer

**Best For**: Diagnosing bugs and investigating failures

**Capabilities**:

- Systematic bug investigation
- Generate hypotheses about causes
- Find supporting evidence
- Root cause identification
- No fixing, just diagnosis

**Example Use Cases**:

- "Investigate why authentication is failing"
- "Diagnose CSV corruption for certain users"
- "Analyze why API times out during peak hours"

**When to Use**: Need to understand WHY a bug occurs before fixing

---

### General Purpose

#### generalPurpose

**Best For**: General tasks, research, multi-step operations

**Capabilities**:

- Research complex questions
- Execute multi-step tasks
- Code searching
- Flexible problem-solving

**Example Use Cases**:

- "Research approach for implementing feature X"
- "Search for and analyze authentication patterns"

**When to Use**: No specialized agent fits, or exploratory work

---

#### shell

**Best For**: Command execution, git operations, terminal tasks

**Capabilities**:

- Run bash commands
- Git operations
- Terminal automation
- Script execution

**Example Use Cases**:

- "Run git status and diff"
- "Execute deployment script"
- "Batch file operations"

**When to Use**: Need command-line operations

---

#### implementor

**Best For**: Executing specific tasks from a master plan

**Capabilities**:

- Implement assigned task
- Follow detailed instructions
- Read context documents
- Validate changes

**Example Use Cases**:

- Used by implement-plan skill
- Execute task 1.1 from parallel-plan.md

**When to Use**: Automated by planning skills, not directly

---

#### research-specialist

**Best For**: Non-code research, fact-checking, gathering information

**Capabilities**:

- Web-based research
- Fact checking with citations
- Market research
- Authoritative sources

**Example Use Cases**:

- "Research electric vehicle market in Europe"
- "Verify renewable energy statistics"

**When to Use**: Need research on non-code topics

---

## Selection Matrix

| Task Type        | Primary Agent                               | Supporting Agents                             |
| ---------------- | ------------------------------------------- | --------------------------------------------- |
| New Feature      | Implementation agent (frontend/backend)     | test-strategy-planner, documentation-writer   |
| Bug Fix          | root-cause-analyzer                         | Implementation agent, test-strategy-planner   |
| Refactoring      | codebase-research-analyst                   | Implementation agents, documentation-writer   |
| Documentation    | documentation-writer or api-docs-expert     | codebase-research-analyst                     |
| Database Work    | db-modifier or sql-database-architect       | documentation-writer                          |
| Infrastructure   | terraform-architect or cloudflare-architect | documentation-writer                          |
| Testing          | test-strategy-planner                       | Implementation agent for test code            |
| Code Exploration | explore or code-finder                      | codebase-research-analyst for deeper analysis |

## Agent Selection Guidelines

1. **Match specialization to task**: Use the most specific agent for the task type
2. **Research before implementation**: Use research/analysis agents before implementation agents
3. **Separate concerns**: Don't overlap responsibilities between agents
4. **Use supporting agents**: Tests and docs are often needed alongside implementation
5. **Consider depth needed**:
   - Quick searches -> explore
   - Find specific code -> code-finder
   - Deep analysis -> codebase-research-analyst

## Common Orchestration Patterns

### Pattern: Feature Implementation

1. codebase-research-analyst (understand existing patterns)
2. frontend-ui-developer + nodejs-backend-architect (parallel implementation)
3. test-strategy-planner (test planning)
4. documentation-writer (document feature)

### Pattern: Bug Investigation & Fix

1. root-cause-analyzer (diagnose root cause)
2. Implementation agent (implement fix)
3. test-strategy-planner (prevent regression)
4. documentation-writer (update docs if needed)

### Pattern: Refactoring

1. codebase-research-analyst (analyze current architecture)
2. Multiple implementation agents (refactor different components in parallel)
3. test-strategy-planner (ensure tests still pass)
4. documentation-writer (update architecture docs)

### Pattern: Documentation Update

1. codebase-research-analyst (understand code)
2. api-docs-expert (API documentation)
3. documentation-writer (feature and usage docs)

---

_This catalog is based on available agents in the Agent tool. Refer to Agent tool description for latest updates._

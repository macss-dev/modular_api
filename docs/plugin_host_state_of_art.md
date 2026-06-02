# State of the Art for Plugin Host Contracts in Modular API Frameworks

## Abstract

This report investigates mature plugin ecosystems to extract engineering practices that can inform a future plugin host contract for modular_api. Across Fastify, Pluggy, VS Code, Grafana, Kong Gateway, and Rollup, the recurring patterns are explicit extension points, host-owned lifecycle orchestration, constrained capability exchange, deterministic ordering, and startup-time validation of metadata and compatibility [@fastifyPlugins; @pluggyDocs; @vscodeExtensionHost; @vscodeContributionPoints; @grafanaPluginJson; @kongHandler; @rollupPluginDev]. The evidence also suggests that API-centric hosts benefit from a hybrid contract: declarative metadata for discovery, validation, and compatibility, plus imperative hooks for request, response, or build-time execution [@vscodeContributionPoints; @grafanaPluginJson; @kongHandler; @rollupPluginDev].

## Research Question

What state-of-the-art engineering practices and reference plugin ecosystems should inform the design of a plugin host contract for modular_api's planned minimal-core HTTP API architecture?

## Scope and Constraints

- In scope: official documentation from mature plugin or extension ecosystems that expose concrete practices for lifecycle hooks, extension points, dependency or capability exchange, ordering, compatibility, validation, and runtime constraints.
- In scope: systems that are close to modular_api's future problem from at least one angle, including HTTP frameworks, gateways, build tooling, IDE extensions, and pluggable host libraries.
- Out of scope: the final modular_api API design, language-specific SDK implementation details, and marketplace economics beyond what the fetched official sources explicitly state.
- Constraint: the report prioritizes official documentation over blog posts or secondary commentary, which improves traceability but limits access to incident history and maintainer rationale beyond what the docs expose [@fastifyPlugins; @pluggyDocs; @vscodeExtensionHost; @grafanaPluginJson; @kongHandler; @rollupPluginDev].
- Constraint: the intended Backstage backend architecture page could not be extracted during research, so Backstage appears only as a discovery and triage note rather than a primary evidence source [@backstagePluginsLegacy].

## Method (Staged Protocol)

The investigation followed the staged protocol required by the research workflow.

1. Stage 1 normalized the problem into host-contract concerns rather than plugin-specific feature design.
2. Stage 2 collected candidate sources from official documentation across multiple ecosystems.
3. Stage 3 scored those sources for relevance, credibility, recency, and evidence type.
4. Stage 4 extracted direct evidence about lifecycle, isolation, validation, ordering, and inter-plugin collaboration.
5. Stage 5 synthesized agreements, tensions, and confidence levels, then translated them into implications for modular_api.

## Findings by Stage

### Stage 1 - Problem Framing

The design problem is not "how to add one more optional feature" but "what host contract lets many optional plugins extend a minimal core without turning each plugin requirement into a new core field or special case" [@pluggyDocs; @fastifyPlugins; @rollupPluginDev]. Mature plugin systems repeatedly separate host extension points from plugin-specific behavior, which is exactly the distinction modular_api needs before formalizing official plugins such as health, metrics, docs, OpenAPI, or later GraphQL [@vscodeContributionPoints; @kongHandler; @grafanaPluginJson].

The investigation therefore used the following success criteria:

- Identify patterns for explicit extension points and registration boundaries.
- Identify patterns for startup and runtime lifecycle control.
- Identify safe mechanisms for plugin-to-plugin collaboration.
- Identify validation, compatibility, and ordering practices that scale beyond a single official plugin.
- Distinguish which lessons are general host-contract practices and which are ecosystem-specific implementation details.

### Stage 2 - Source Discovery

The candidate set intentionally mixed different host styles so that the final conclusions would not overfit one framework family [@fastifyPlugins; @pluggyDocs; @vscodeExtensionHost; @grafanaPluginJson; @kongHandler; @rollupPluginDev].

| Key | Source | Type | Candidate value |
| --- | --- | --- | --- |
| fastifyPlugins | Fastify Plugins | Official framework reference | Documents scoped plugin registration, encapsulation, decorators, route prefixing, lifecycle completion, and version-gated plugin wrapping through fastify-plugin [@fastifyPlugins] |
| pluggyDocs | Pluggy documentation | Official host-library reference | Documents hook specifications, plugin registration, validation, ordering, wrappers, historic hooks, inspection, and semver-based evolution for a host that powers pytest and 1400+ plugins [@pluggyDocs] |
| vscodeExtensionHost | VS Code Extension Host | Official platform architecture doc | Documents separate extension hosts, runtime and location selection, lazy activation, and performance and stability constraints for a large extension platform [@vscodeExtensionHost] |
| vscodeContributionPoints | VS Code Contribution Points | Official manifest reference | Documents declarative contribution points, schema-like validation, activation events, unique identifiers, conditional enablement, and self-contained configuration schemas [@vscodeContributionPoints] |
| grafanaPluginJson | Grafana plugin.json reference | Official platform manifest reference | Documents required plugin manifests, discovery by manifest scanning, compatibility fields, dependency declarations, extension points, exposed components, routes, IAM, and RBAC metadata [@grafanaPluginJson] |
| kongHandler | Kong Gateway handler.lua | Official gateway plugin reference | Documents request and stream lifecycle phases, plugin handler entry points, phase-specific constraints, plugin configuration delivery, PDK usage, and priority-based execution ordering [@kongHandler] |
| rollupPluginDev | Rollup Plugin Development | Official tooling reference | Documents explicit hook categories, hook ordering and execution kinds, plugin context APIs, inter-plugin communication patterns, emitted assets, and lifecycle separation between build and output phases [@rollupPluginDev] |
| backstagePluginsLegacy | Backstage Introduction to Plugins (Legacy) | Official but legacy intro page | Confirms an ecosystem-scale plugin vision and plugin directory, but does not provide enough host-contract mechanics for primary evidence and is explicitly marked legacy [@backstagePluginsLegacy] |

### Stage 3 - Source Triage

The curated set retained the sources that directly expose host-contract mechanics and dropped sources that were either redundant or too shallow for contract design [@fastifyPlugins; @pluggyDocs; @vscodeExtensionHost; @vscodeContributionPoints; @grafanaPluginJson; @kongHandler; @rollupPluginDev; @backstagePluginsLegacy].

| Key | Keep | Relevance | Credibility | Recency | Evidence type | Rationale |
| --- | --- | --- | --- | --- | --- | --- |
| fastifyPlugins | Yes | 5/5 | 5/5 | 4/5 | Official reference | Very close to modular_api because it shows how a server host can combine route registration, encapsulation, decorators, and lifecycle completion while protecting parent scopes by default [@fastifyPlugins] |
| pluggyDocs | Yes | 5/5 | 5/5 | 5/5 | Official reference plus ecosystem signal | High-value source for explicit host and plugin boundaries, validation, ordering, wrappers, evolution, and evidence of large-scale use through pytest's plugin ecosystem [@pluggyDocs] |
| vscodeExtensionHost | Yes | 4/5 | 5/5 | 5/5 | Official architecture doc | Strong source for runtime isolation, lazy activation, and host responsibility for stability and performance [@vscodeExtensionHost] |
| vscodeContributionPoints | Yes | 5/5 | 5/5 | 5/5 | Official manifest reference | Strong source for declarative extension metadata, schema validation, unique identifiers, and conditional enablement [@vscodeContributionPoints] |
| grafanaPluginJson | Yes | 5/5 | 5/5 | 5/5 | Official manifest reference | Strong source for required metadata, dependency declarations, extension-point versioning, capability exposure, and operational metadata such as routes and IAM [@grafanaPluginJson] |
| kongHandler | Yes | 5/5 | 5/5 | 5/5 | Official gateway reference | Strong source for API-gateway lifecycle phases, phase restrictions, host-owned execution order, and request-time constraints that are especially relevant to HTTP plugin hosts [@kongHandler] |
| rollupPluginDev | Yes | 4/5 | 5/5 | 5/5 | Official tooling reference | Strong source for deterministic hook semantics, hook kinds, and explicit inter-plugin collaboration patterns, even though its domain is build tooling rather than HTTP [@rollupPluginDev] |
| backstagePluginsLegacy | No, primary evidence dropped | 2/5 | 4/5 | 3/5 | Official but legacy intro | Useful as discovery context only because the accessible page is marked legacy and focuses on ecosystem introduction rather than host-contract mechanics [@backstagePluginsLegacy] |

### Stage 4 - Evidence Extraction

The curated sources converge on several repeatable engineering practices.

#### 1. Successful plugin hosts make extension points explicit and host-owned

Fastify requires plugins to register through the host's register API and documents that registration creates a new scope by default, which gives the host control over inheritance and visibility [@fastifyPlugins]. Pluggy requires the host to define hook specifications that the PluginManager validates against plugin implementations instead of relying on monkey patching or hidden overrides [@pluggyDocs]. Kong only invokes plugin handlers with predetermined phase names returned from handler.lua, which makes the execution surface explicit and closed by default [@kongHandler]. Rollup exposes named hooks with defined execution semantics, and VS Code and Grafana enumerate declarative contribution points or manifest fields rather than letting plugins mutate arbitrary host internals [@rollupPluginDev; @vscodeContributionPoints; @grafanaPluginJson].

Representative evidence:

> "register always creates a new Fastify scope ... creating a directed acyclic graph (DAG) and avoiding cross-dependency issues." [@fastifyPlugins]

> Pluggy "does not rely" on overriding or monkey patching and instead creates a more "loosely coupled" relationship between host and plugins through hookspecs and hookimpls [@pluggyDocs].

> "A plugin's handler.lua must return a table containing the functions it must execute on each phase." [@kongHandler]

#### 2. Encapsulation and constrained capability exchange are preferred over ambient shared state

Fastify's default scope creation prevents decorations from leaking upward and therefore forces an explicit decision when broader visibility is needed [@fastifyPlugins]. Pluggy explicitly argues that the host should think carefully about which objects are exposed to hooks so that extensions operate through a narrow, designed interface rather than through broad state access [@pluggyDocs]. Rollup recommends explicit inter-plugin communication through custom resolver options, module meta-data, or a deliberately exposed plugin API instead of proxy identifiers or hidden coupling [@rollupPluginDev]. Kong provides a forward-compatible Plugin Development Kit rather than asking plugins to reach into internal gateway structures directly [@kongHandler]. VS Code places extensions in dedicated extension hosts and treats isolation as part of the platform contract for stability and performance [@vscodeExtensionHost].

Representative evidence:

> VS Code states that misbehaving extensions should not impact the user experience and that the extension host prevents extensions from impacting startup performance, slowing UI operations, or modifying the UI directly [@vscodeExtensionHost].

> Rollup recommends custom resolver options and JSON-serializable module meta-data for inter-plugin communication and also documents a direct plugin API pattern when a stronger dependency is intended [@rollupPluginDev].

#### 3. Declarative metadata and startup validation are a separate concern from runtime hooks

Grafana requires plugin.json for all plugins, discovers plugins by scanning for that manifest, and validates structured metadata such as plugin id patterns, compatibility declarations, dependency lists, extension points, exposed components, routes, IAM, and RBAC-related fields [@grafanaPluginJson]. VS Code contribution points are declared in package.json and use schema-like structures with unique ids, required properties, explicit activation events, and self-contained configuration schemas [@vscodeContributionPoints]. Pluggy supports host-side validation through hookspecs, check_pending, optional hooks, deprecation warnings, and semver for controlled evolution [@pluggyDocs]. Fastify's recommended fastify-plugin wrapper can declare the supported Fastify version range, which turns compatibility into an explicit registration concern instead of a runtime surprise [@fastifyPlugins].

Representative evidence:

> "The plugin.json file is required for all plugins" and Grafana mounts folders that contain it when Grafana starts [@grafanaPluginJson].

> VS Code documents contribution points as JSON declarations in the contributes field of the extension manifest and also documents that configuration schemas must be self-contained and use unique identifiers [@vscodeContributionPoints].

> Pluggy documents both strict or optional spec validation and warns on deprecated hook implementations or hook arguments [@pluggyDocs].

#### 4. Lifecycle and ordering semantics must be deterministic

Kong processes plugins in named phases such as init_worker, configure, rewrite, access, response, and log, and it sorts plugins by PRIORITY so that higher-priority plugins run first in each phase [@kongHandler]. Rollup classifies hooks as first, sequential, or parallel and allows additional pre or post ordering, which shows that hook timing and concurrency rules are part of the contract rather than incidental behavior [@rollupPluginDev]. Pluggy supports LIFO default calling, tryfirst, trylast, wrappers, firstresult, historic hooks, blocking, and unregistering, which again turns ordering into an explicit host responsibility [@pluggyDocs]. Fastify documents after and ready as lifecycle checkpoints for registration completion and error handling, and it also documents that preceding plugins can make decorated capabilities available to later ones according to registration order [@fastifyPlugins].

Representative evidence:

> Kong states that "PRIORITY is used to sort plugins before executing each of their phases" and that higher priority executes sooner [@kongHandler].

> Rollup documents hook kinds as async or sync and first, sequential, or parallel, with additional pre or post ordering and sequential overrides for otherwise parallel hooks [@rollupPluginDev].

#### 5. Hosts need an explicit story for late loading, inspection, and operational visibility

Pluggy includes registry inspection, tracing, call monitoring, historic hooks for late registration, blocking, and subset hook callers, which indicates that observability and operability belong in the host contract once plugins accumulate [@pluggyDocs]. VS Code uses activation events and lazy loading to control startup and resource usage, which makes the host responsible for when plugin code actually activates [@vscodeExtensionHost; @vscodeContributionPoints]. Grafana distinguishes default lazy initialization from preload and explicitly warns plugin authors to mitigate preload performance costs with code splitting [@grafanaPluginJson]. Kong separates worker-time configure and init_worker from request-time phases, which avoids request-path reconfiguration and gives the host a clean place to rebuild plugin state [@kongHandler].

Representative evidence:

> VS Code states that extensions declare activation events and are loaded lazily so that they do not consume unnecessary CPU and memory before they are relevant [@vscodeExtensionHost].

> Grafana documents that preload initializes an app plugin on startup and warns implementers to minimize performance impact with frontend code splitting [@grafanaPluginJson].

#### 6. Ecosystem-scale cases show why these controls matter

Pluggy is the strongest direct success case in the curated evidence because its documentation explicitly states that it powers pytest's plugin system and enables 1400+ plugins, while also noting that pytest itself is composed as a set of Pluggy plugins [@pluggyDocs]. Kong's reference docs list a large catalog of bundled plugins with fixed priorities across authentication, validation, transformation, rate limiting, and observability, which demonstrates that deterministic ordering becomes operationally necessary once many plugins coexist in one request pipeline [@kongHandler]. Backstage's accessible page is legacy, but it still confirms a plugin-directory model and describes a broad plugin vision, which is useful as ecosystem context even though it was not used as primary design evidence [@backstagePluginsLegacy].

### Stage 5 - Synthesis and Limits

The strongest cross-source agreements are the following.

- High confidence: durable plugin hosts define explicit contribution points and reject undeclared behavior at registration or startup time because the curated systems consistently model extension surfaces as named hooks, manifests, or predetermined phase handlers rather than as arbitrary mutation of host internals [@pluggyDocs; @vscodeContributionPoints; @kongHandler; @rollupPluginDev; @grafanaPluginJson].
- High confidence: lifecycle and ordering semantics are part of the public contract, not an implementation detail, because every curated primary source documents explicit load phases, completion points, priorities, or hook-execution categories [@fastifyPlugins; @pluggyDocs; @kongHandler; @rollupPluginDev; @vscodeExtensionHost].
- High confidence: plugin collaboration should go through explicit capabilities, hook arguments, or versioned extension identifiers rather than hidden shared state, which is a repeated pattern in Pluggy, Rollup, Fastify, Grafana, and Kong's PDK model [@pluggyDocs; @rollupPluginDev; @fastifyPlugins; @grafanaPluginJson; @kongHandler].
- Medium confidence: modular_api should adopt a hybrid contract with declarative metadata plus imperative runtime hooks because the most relevant references split discovery, validation, and compatibility metadata from execution-time behavior [@vscodeContributionPoints; @grafanaPluginJson; @kongHandler; @rollupPluginDev].
- Medium confidence: modular_api will likely need separate but compatible surfaces for global plugins and more local contributions because the curated sources repeatedly separate scope, phase, or extension-point locality from the common host model [@fastifyPlugins; @kongHandler; @grafanaPluginJson].

The main tension across the sources is that some ecosystems emphasize declarative manifests more strongly, while others emphasize executable hooks more strongly [@vscodeContributionPoints; @grafanaPluginJson; @pluggyDocs; @kongHandler; @rollupPluginDev]. For modular_api, that tension is not a contradiction but a design signal: API plugins need imperative execution hooks for HTTP behavior, but they also need declarative registration data for discovery, compatibility, conflict detection, and documentation [@kongHandler; @grafanaPluginJson; @vscodeContributionPoints].

## Discussion

For modular_api, the evidence supports a host contract built on a small number of explicit principles rather than a broad core API surface [@fastifyPlugins; @pluggyDocs; @grafanaPluginJson; @kongHandler; @rollupPluginDev].

- A plugin should likely declare identity, version, compatibility range, required capabilities or dependencies, and the contribution categories it intends to use before any runtime logic is executed, because Grafana, VS Code, Fastify, and Kong all separate registration metadata from runtime behavior in some form [@grafanaPluginJson; @vscodeContributionPoints; @fastifyPlugins; @kongHandler].
- The runtime side should likely expose a small, versioned host API with explicit lifecycle hooks and explicit capability exchange instead of open access to host internals, because Pluggy, Rollup, Fastify, and Kong all work by constraining extension interactions to documented surfaces [@pluggyDocs; @rollupPluginDev; @fastifyPlugins; @kongHandler].
- A capability registry or equivalent explicit collaboration mechanism is better supported by the evidence than hidden fields on the core object, because Rollup's custom resolver options and meta, Pluggy's hook contracts, Fastify's decorator visibility rules, and Grafana's versioned extension identifiers all favor deliberate and namespaced collaboration [@rollupPluginDev; @pluggyDocs; @fastifyPlugins; @grafanaPluginJson].
- Deterministic ordering needs to be a first-class part of the contract once official plugins multiply, because Kong, Rollup, and Pluggy all devote explicit surface area to priority or ordering semantics and do not leave cross-plugin order to accident [@kongHandler; @rollupPluginDev; @pluggyDocs].
- Boot-time registration and request-time execution should be separate phases, because VS Code, Grafana, Kong, Rollup, and Fastify all distinguish registration or startup work from the hot execution path [@vscodeExtensionHost; @grafanaPluginJson; @kongHandler; @rollupPluginDev; @fastifyPlugins].
- Official plugins should use the same public contract intended for third-party plugins whenever possible, because Pluggy explicitly notes that pytest itself is composed as plugins and Kong's built-in plugins participate in the same priority-ordered execution model documented for custom plugins [@pluggyDocs; @kongHandler].

These implications do not yet define the final modular_api contract, but they narrow the design space substantially [@fastifyPlugins; @pluggyDocs; @grafanaPluginJson; @kongHandler; @rollupPluginDev]. They argue against a host that grows ad hoc plugin-specific fields, and they argue for a host that combines manifest validation, lifecycle orchestration, explicit capabilities, and deterministic contribution points [@vscodeContributionPoints; @grafanaPluginJson; @kongHandler; @rollupPluginDev].

## Conclusion

The state of the art points to five durable invariants for a plugin host contract that aims to scale beyond one or two official plugins: explicit extension points, a hybrid metadata-plus-runtime model, capability-based collaboration, deterministic lifecycle and ordering semantics, and startup-time validation of compatibility and conflicts [@pluggyDocs; @vscodeContributionPoints; @grafanaPluginJson; @kongHandler; @rollupPluginDev; @fastifyPlugins]. For modular_api, those invariants are more important than any single ecosystem-specific API shape because they address the underlying host problem that appears across HTTP frameworks, gateways, tooling, and extension platforms [@fastifyPlugins; @pluggyDocs; @vscodeExtensionHost; @grafanaPluginJson; @kongHandler; @rollupPluginDev].

## Limitations

- The evidence base is limited to official documentation and reference manuals, so it is stronger on intended contracts than on undocumented production failure modes.
- The Backstage backend architecture page could not be extracted during research, and the accessible Backstage page was explicitly marked legacy, so Backstage was excluded from the primary evidence set [@backstagePluginsLegacy].
- The curated sources provide uneven ecosystem-scale evidence; Pluggy explicitly cites 1400+ plugins, while the other sources mainly provide architecture and reference material rather than adoption metrics [@pluggyDocs].
- No direct postmortems or benchmark studies were retrieved, so conclusions about isolation and operational safety rely on documented architecture and constraints rather than incident data [@vscodeExtensionHost; @kongHandler].

## References

```bibtex
@online{fastifyPlugins,
  title={Plugins},
  author={{Fastify Contributors}},
  note={Accessed: 2026-06-01},
  url={https://fastify.dev/docs/latest/Reference/Plugins/}
}

@online{pluggyDocs,
  title={pluggy Documentation},
  author={{pluggy and pytest-dev Contributors}},
  note={Accessed: 2026-06-01},
  url={https://pluggy.readthedocs.io/en/stable/}
}

@online{vscodeExtensionHost,
  title={Extension Host},
  author={{Microsoft}},
  note={Accessed: 2026-06-01},
  url={https://code.visualstudio.com/api/advanced-topics/extension-host}
}

@online{vscodeContributionPoints,
  title={Contribution Points},
  author={{Microsoft}},
  note={Accessed: 2026-06-01},
  url={https://code.visualstudio.com/api/references/contribution-points}
}

@online{grafanaPluginJson,
  title={Plugin metadata (plugin.json)},
  author={{Grafana Labs}},
  note={Accessed: 2026-06-01},
  url={https://grafana.com/developers/plugin-tools/reference/plugin-json}
}

@online{kongHandler,
  title={handler.lua},
  author={{Kong Inc.}},
  note={Accessed: 2026-06-01},
  url={https://developer.konghq.com/custom-plugins/handler.lua/}
}

@online{rollupPluginDev,
  title={Plugin Development},
  author={{Rollup Contributors}},
  note={Accessed: 2026-06-01},
  url={https://rollupjs.org/plugin-development/}
}

@online{backstagePluginsLegacy,
  title={Introduction to Plugins (Legacy)},
  author={{Backstage Project Authors}},
  note={Accessed: 2026-06-01},
  url={https://backstage.io/docs/plugins/}
}
```
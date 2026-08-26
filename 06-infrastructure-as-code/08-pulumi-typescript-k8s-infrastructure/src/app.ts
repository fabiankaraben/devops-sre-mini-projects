import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";

export interface MicroserviceAppArgs {
  namespace: pulumi.Input<string>;
  environment: pulumi.Input<string>;
  image?: string;
  replicas: pulumi.Input<number>;
  port: pulumi.Input<number>;
  config?: Record<string, string>;
  cpuRequest?: string;
  memoryRequest?: string;
  cpuLimit?: string;
  memoryLimit?: string;
  enableNetworkPolicy?: boolean;
  extraLabels?: Record<string, string>;
}

/**
 * MicroserviceApp is a custom Pulumi ComponentResource that encapsulates
 * a production-grade Kubernetes microservice, including:
 * 1. ConfigMap with application settings and feature flags
 * 2. Hardened Deployment with resource limits, security context, and health probes
 * 3. Service for internal cluster DNS discovery
 * 4. Optional NetworkPolicy for network boundary isolation
 */
export class MicroserviceApp extends pulumi.ComponentResource {
  public readonly configMap: k8s.core.v1.ConfigMap;
  public readonly deployment: k8s.apps.v1.Deployment;
  public readonly service: k8s.core.v1.Service;
  public readonly networkPolicy?: k8s.networking.v1.NetworkPolicy;
  public readonly serviceEndpoint: pulumi.Output<string>;

  constructor(name: string, args: MicroserviceAppArgs, opts?: pulumi.ComponentResourceOptions) {
    super("custom:k8s:MicroserviceApp", name, {}, opts);

    const appLabels = {
      "app.kubernetes.io/name": name,
      "app.kubernetes.io/instance": name,
      "app.kubernetes.io/managed-by": "pulumi",
      "environment": pulumi.output(args.environment),
      ...(args.extraLabels || {}),
    };

    // 1. ConfigMap for application configuration
    this.configMap = new k8s.core.v1.ConfigMap(
      `${name}-config`,
      {
        metadata: {
          name: `${name}-config`,
          namespace: args.namespace,
          labels: appLabels,
        },
        data: {
          APP_NAME: name,
          SERVICE_PORT: pulumi.output(args.port).apply((p) => p.toString()),
          ENVIRONMENT: pulumi.output(args.environment),
          LOG_LEVEL: pulumi.output(args.environment).apply((env) => (env === "prod" ? "info" : "debug")),
          ...(args.config || {}),
        },
      },
      { parent: this }
    );

    // 2. Deployment with SRE best practices (security context, probes, resource limits)
    const image = args.image || "hashicorp/http-echo:latest";
    const port = args.port;

    this.deployment = new k8s.apps.v1.Deployment(
      `${name}-deployment`,
      {
        metadata: {
          name: `${name}-deployment`,
          namespace: args.namespace,
          labels: appLabels,
        },
        spec: {
          replicas: args.replicas,
          selector: {
            matchLabels: {
              "app.kubernetes.io/name": name,
            },
          },
          template: {
            metadata: {
              labels: appLabels,
            },
            spec: {
              securityContext: {
                runAsNonRoot: true,
                runAsUser: 10001,
                runAsGroup: 10001,
                fsGroup: 10001,
              },
              containers: [
                {
                  name: name,
                  image: image,
                  args: [
                    pulumi.interpolate`-text={"service":"${name}","status":"ok","env":"${args.environment}"}`,
                    pulumi.interpolate`-listen=:${port}`,
                  ],
                  ports: [
                    {
                      name: "http",
                      containerPort: port,
                    },
                  ],
                  envFrom: [
                    {
                      configMapRef: {
                        name: this.configMap.metadata.name,
                      },
                    },
                  ],
                  resources: {
                    requests: {
                      cpu: args.cpuRequest || "50m",
                      memory: args.memoryRequest || "64Mi",
                    },
                    limits: {
                      cpu: args.cpuLimit || "200m",
                      memory: args.memoryLimit || "128Mi",
                    },
                  },
                  securityContext: {
                    allowPrivilegeEscalation: false,
                    readOnlyRootFilesystem: true,
                    capabilities: {
                      drop: ["ALL"],
                    },
                  },
                  livenessProbe: {
                    httpGet: {
                      path: "/",
                      port: port,
                    },
                    initialDelaySeconds: 3,
                    periodSeconds: 10,
                    timeoutSeconds: 2,
                    failureThreshold: 3,
                  },
                  readinessProbe: {
                    httpGet: {
                      path: "/",
                      port: port,
                    },
                    initialDelaySeconds: 2,
                    periodSeconds: 5,
                    timeoutSeconds: 2,
                    successThreshold: 1,
                    failureThreshold: 2,
                  },
                },
              ],
            },
          },
        },
      },
      { parent: this }
    );

    // 3. ClusterIP Service for internal DNS discovery
    this.service = new k8s.core.v1.Service(
      `${name}-svc`,
      {
        metadata: {
          name: `${name}-svc`,
          namespace: args.namespace,
          labels: appLabels,
        },
        spec: {
          type: "ClusterIP",
          ports: [
            {
              name: "http",
              port: port,
              targetPort: "http",
              protocol: "TCP",
            },
          ],
          selector: {
            "app.kubernetes.io/name": name,
          },
        },
      },
      { parent: this }
    );

    // 4. Optional NetworkPolicy
    if (args.enableNetworkPolicy) {
      this.networkPolicy = new k8s.networking.v1.NetworkPolicy(
        `${name}-netpol`,
        {
          metadata: {
            name: `${name}-netpol`,
            namespace: args.namespace,
            labels: appLabels,
          },
          spec: {
            podSelector: {
              matchLabels: {
                "app.kubernetes.io/name": name,
              },
            },
            policyTypes: ["Ingress", "Egress"],
            ingress: [
              {
                from: [
                  {
                    namespaceSelector: {
                      matchLabels: {
                        "app.kubernetes.io/managed-by": "pulumi",
                      },
                    },
                  },
                ],
                ports: [
                  {
                    port: port,
                    protocol: "TCP",
                  },
                ],
              },
            ],
            egress: [
              {
                to: [], // Allow necessary cluster DNS / external egress
              },
            ],
          },
        },
        { parent: this }
      );
    }

    // Export internal cluster DNS endpoint
    this.serviceEndpoint = pulumi.interpolate`${this.service.metadata.name}.${args.namespace}.svc.cluster.local:${port}`;

    this.registerOutputs({
      configMap: this.configMap,
      deployment: this.deployment,
      service: this.service,
      serviceEndpoint: this.serviceEndpoint,
    });
  }
}

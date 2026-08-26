import * as pulumi from "@pulumi/pulumi";
import * as k8s from "@pulumi/kubernetes";
import { MicroserviceApp } from "./src/app";

// 1. Read Stack Configuration
const config = new pulumi.Config();
const environment = config.get("environment") || "dev";
const defaultReplicas = environment === "prod" ? 3 : 1;
const replicaCount = config.getNumber("replicaCount") || defaultReplicas;
const appPort = config.getNumber("appPort") || 8080;
const enableNetworkPolicy = config.getBoolean("enableNetworkPolicy") ?? (environment === "prod");

// 2. Create Isolated Kubernetes Namespace
const namespaceName = `pulumi-fleet-${environment}`;

export const namespace = new k8s.core.v1.Namespace(
  "app-namespace",
  {
    metadata: {
      name: namespaceName,
      labels: {
        "name": namespaceName,
        "app.kubernetes.io/managed-by": "pulumi",
        "environment": environment,
        "tier": "fleet-workloads",
      },
    },
  }
);

// 3. Define Microservice Fleet Specifications
export interface ServiceSpec {
  name: string;
  config: Record<string, string>;
  cpuRequest?: string;
  memoryRequest?: string;
}

export const services: ServiceSpec[] = [
  {
    name: "frontend",
    config: {
      TIER: "presentation",
      CACHE_ENABLED: "true",
      PUBLIC_URL: `https://${environment}.fleet.local`,
    },
    cpuRequest: "50m",
    memoryRequest: "64Mi",
  },
  {
    name: "api",
    config: {
      TIER: "business-logic",
      DATABASE_HOST: "postgres.internal",
      MAX_CONNECTIONS: environment === "prod" ? "100" : "10",
    },
    cpuRequest: "100m",
    memoryRequest: "128Mi",
  },
  {
    name: "auth",
    config: {
      TIER: "security",
      TOKEN_TTL: "3600",
      ISSUER: "fleet-idp",
    },
    cpuRequest: "50m",
    memoryRequest: "64Mi",
  },
];

// 4. Provision Fleet Microservices using Reusable ComponentResource
export const appInstances: Record<string, MicroserviceApp> = {};
export const endpoints: Record<string, pulumi.Output<string>> = {};

for (const svc of services) {
  const app = new MicroserviceApp(
    svc.name,
    {
      namespace: namespace.metadata.name,
      environment: environment,
      replicas: replicaCount,
      port: appPort,
      config: svc.config,
      cpuRequest: svc.cpuRequest,
      memoryRequest: svc.memoryRequest,
      enableNetworkPolicy: enableNetworkPolicy,
    },
    { dependsOn: [namespace] }
  );

  appInstances[svc.name] = app;
  endpoints[svc.name] = app.serviceEndpoint;
}

// 5. Export Stack Outputs for SRE & CI/CD Pipelines
export const exportedNamespace = namespace.metadata.name;
export const activeEnvironment = environment;
export const perServiceReplicas = replicaCount;
export const totalMicroservices = services.length;
export const totalReplicas = replicaCount * services.length;
export const appEndpoints = endpoints;

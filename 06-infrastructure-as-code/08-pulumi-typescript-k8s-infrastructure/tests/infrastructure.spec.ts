import * as pulumi from "@pulumi/pulumi";
import { expect } from "chai";

function promiseOf<T>(output: pulumi.Output<T>): Promise<T> {
  return new Promise((resolve) => output.apply(resolve));
}

describe("Kubernetes Infrastructure Unit Tests (Pulumi Mocks)", () => {
  let infra: typeof import("../index");

  before(async () => {
    // 1. Initialize Pulumi runtime mocks before loading stack
    pulumi.runtime.setMocks(
      {
        newResource: (args: pulumi.runtime.MockResourceArgs): { id: string; state: Record<string, any> } => {
          return {
            id: `${args.name}-mock-id`,
            state: {
              ...args.inputs,
            },
          };
        },
        call: (args: pulumi.runtime.MockCallArgs): Record<string, any> => {
          return args.inputs;
        },
      },
      "k8s-pulumi-fleet",
      "dev",
      false
    );

    // 2. Dynamically load stack code
    infra = require("../index");
  });

  describe("1. Namespace Governance & Compliance", () => {
    it("should provision namespace with standard managed-by and environment labels", async () => {
      const metadata = await promiseOf(infra.namespace.metadata);
      expect(metadata).to.exist;
      expect(metadata.labels).to.exist;
      expect(metadata.labels!["app.kubernetes.io/managed-by"]).to.equal("pulumi");
      expect(metadata.labels!["environment"]).to.equal("dev");
      expect(metadata.labels!["tier"]).to.equal("fleet-workloads");
    });
  });

  describe("2. SRE Workload Security Standards", () => {
    it("should enforce runAsNonRoot at pod securityContext level", async () => {
      const apps = Object.values(infra.appInstances);
      expect(apps.length).to.equal(3);

      for (const app of apps) {
        const spec = await promiseOf(app.deployment.spec);
        const podSpec = spec.template.spec;
        expect(podSpec.securityContext).to.exist;
        expect(podSpec.securityContext!.runAsNonRoot).to.be.true;
        expect(podSpec.securityContext!.runAsUser).to.equal(10001);
      }
    });

    it("should enforce container security restrictions (no privilege escalation, drop all capabilities)", async () => {
      const apps = Object.values(infra.appInstances);
      for (const app of apps) {
        const spec = await promiseOf(app.deployment.spec);
        for (const container of spec.template.spec.containers) {
          expect(container.securityContext).to.exist;
          expect(container.securityContext!.allowPrivilegeEscalation).to.be.false;
          expect(container.securityContext!.readOnlyRootFilesystem).to.be.true;
          expect(container.securityContext!.capabilities).to.exist;
          expect(container.securityContext!.capabilities!.drop).to.include("ALL");
        }
      }
    });
  });

  describe("3. Resource Limits & SRE Reliability", () => {
    it("should require both CPU and Memory requests and limits for all containers", async () => {
      const apps = Object.values(infra.appInstances);
      for (const app of apps) {
        const spec = await promiseOf(app.deployment.spec);
        for (const container of spec.template.spec.containers) {
          expect(container.resources).to.exist;
          expect(container.resources!.requests).to.exist;
          expect(container.resources!.requests!["cpu"]).to.exist;
          expect(container.resources!.requests!["memory"]).to.exist;
          expect(container.resources!.limits).to.exist;
          expect(container.resources!.limits!["cpu"]).to.exist;
          expect(container.resources!.limits!["memory"]).to.exist;
        }
      }
    });

    it("should configure both Liveness and Readiness HTTP probes", async () => {
      const apps = Object.values(infra.appInstances);
      for (const app of apps) {
        const spec = await promiseOf(app.deployment.spec);
        for (const container of spec.template.spec.containers) {
          expect(container.livenessProbe).to.exist;
          expect(container.livenessProbe!.httpGet).to.exist;
          expect(container.readinessProbe).to.exist;
          expect(container.readinessProbe!.httpGet).to.exist;
        }
      }
    });
  });

  describe("4. Networking & Service Discovery", () => {
    it("should configure ClusterIP service on port 8080 matching container port", async () => {
      const apps = Object.values(infra.appInstances);
      for (const app of apps) {
        const spec = await promiseOf(app.service.spec);
        expect(spec.type).to.equal("ClusterIP");
        expect(spec.ports).to.exist;
        expect(spec.ports[0].port).to.equal(8080);
      }
    });
  });

  describe("5. Stack Output Integrity", () => {
    it("should export appEndpoints map containing internal cluster DNS records", async () => {
      const endpoints = infra.appEndpoints;
      expect(endpoints).to.exist;
      expect(endpoints["frontend"]).to.exist;
      expect(endpoints["api"]).to.exist;
      expect(endpoints["auth"]).to.exist;

      const frontendEndpoint = await promiseOf(endpoints["frontend"]);
      expect(frontendEndpoint).to.include("frontend-svc");
      expect(frontendEndpoint).to.include(".svc.cluster.local:8080");
    });

    it("should assert total microservice and replica counts", async () => {
      expect(infra.totalMicroservices).to.equal(3);
      expect(infra.totalReplicas).to.equal(3); // 1 replica x 3 services in dev mock
    });
  });
});

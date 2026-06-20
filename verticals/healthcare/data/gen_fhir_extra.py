#!/usr/bin/env python3
"""Generate minimal-but-valid FHIR R4 resources for the resource types that the
HDS silver layer provisions a table for but the Synthea seed does not produce.

Why: the HDS "bronze -> silver flatten" notebook creates one silver table per
FHIR resource type (the full R4 catalog). The Synthea seed only contains ~18
clinical types, so ~150 silver tables come up empty after a deploy. A demo
operator then can't tell "empty because nothing wrote" from "empty by design".

This script synthesizes a small number of structurally valid instances for the
clinically/administratively meaningful resource types, anchored to the *real*
Patient / Encounter / Practitioner / Organization / Device / Immunization ids
already in ``fhir-seed/``. Azure Health Data Services FHIR does not enforce
referential integrity and we PUT by id, so load order is irrelevant and every
reference resolves to a resource that the seed (or this script) also loads.

Only the fields with min-cardinality 1..1 (and their required value-set codes)
are populated; everything else is intentionally omitted. The goal is table
coverage for the demo, not clinical realism.

Output: one ``<ResourceType>.ndjson`` file per type in ``fhir-seed/`` (the same
folder ``seed_fhir.py`` loads from). Re-running is idempotent: resource ids are
derived deterministically with uuid5, so a re-run overwrites the same files and
re-PUTs the same ids.

Usage:
    python gen_fhir_extra.py                 # write into ./fhir-seed
    python gen_fhir_extra.py --seed-dir DIR  # override
    python gen_fhir_extra.py --count 8       # instances per type (default 8)
"""
from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

# Deterministic id namespace so re-runs produce identical ids (PUT upsert).
_NS = uuid.uuid5(uuid.NAMESPACE_URL, "contoso-healthcare-fhir-extra")

# Fixed instants/dates keep output stable across runs.
TS = "2024-01-15T10:00:00Z"
DATE = "2024-01-15"

# Types whose ids we read out of the existing seed to anchor references.
_ANCHOR_TYPES = [
    "Patient", "Encounter", "Practitioner", "Organization",
    "Location", "Device", "Immunization",
]


def _rid(rtype: str, i: int) -> str:
    """Deterministic resource id for a synthesized resource."""
    return str(uuid.uuid5(_NS, f"{rtype}/{i}"))


def _load_anchor_ids(seed_dir: Path) -> dict[str, list[str]]:
    ids: dict[str, list[str]] = {t: [] for t in _ANCHOR_TYPES}
    for t in _ANCHOR_TYPES:
        f = seed_dir / f"{t}.ndjson"
        if not f.exists():
            continue
        with f.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                rid = json.loads(line).get("id")
                if rid:
                    ids[t].append(rid)
    return ids


class Ctx:
    """Anchor data + reference helpers passed to every builder."""

    def __init__(self, anchors: dict[str, list[str]], count: int) -> None:
        self.count = count
        self._a = anchors

    def _ref(self, rtype: str, i: int, ids: list[str]) -> dict:
        if ids:
            return {"reference": f"{rtype}/{ids[i % len(ids)]}"}
        # Fall back to a synthesized id of that type if the seed had none.
        return {"reference": f"{rtype}/{_rid(rtype, i)}"}

    def patient(self, i: int) -> dict:
        return self._ref("Patient", i, self._a["Patient"])

    def encounter(self, i: int) -> dict:
        return self._ref("Encounter", i, self._a["Encounter"])

    def practitioner(self, i: int) -> dict:
        return self._ref("Practitioner", i, self._a["Practitioner"])

    def organization(self, i: int) -> dict:
        return self._ref("Organization", i, self._a["Organization"])

    def location(self, i: int) -> dict:
        return self._ref("Location", i, self._a["Location"])

    def device(self, i: int) -> dict:
        return self._ref("Device", i, self._a["Device"])

    def immunization(self, i: int) -> dict:
        return self._ref("Immunization", i, self._a["Immunization"])

    def self_ref(self, rtype: str, i: int) -> dict:
        """Reference to another resource type this script generates."""
        n = self.count
        return {"reference": f"{rtype}/{_rid(rtype, i % n)}"}


# A generic CodeableConcept used wherever a code field has a non-required
# (example/preferred/extensible) binding — any code is accepted there.
def _cc(text: str = "Demo", code: str = "260385009",
        system: str = "http://snomed.info/sct") -> dict:
    return {"coding": [{"system": system, "code": code, "display": text}], "text": text}


def _coding(code: str, system: str = "http://snomed.info/sct", display: str = "Demo") -> dict:
    return {"system": system, "code": code, "display": display}


# --- builders: each returns the resource body WITHOUT resourceType/id ----------
# Only 1..1 (and required-binding) fields are populated.

def b(**kw):  # tiny helper to keep builders terse
    return kw


BUILDERS = {
    "Account": lambda c, i: b(status="active", name="Demo Account",
                              subject=[c.patient(i)]),
    "ActivityDefinition": lambda c, i: b(status="active", name="DemoActivity"),
    "AdverseEvent": lambda c, i: b(actuality="actual", subject=c.patient(i)),
    "Appointment": lambda c, i: b(status="booked",
                                  participant=[{"status": "accepted", "actor": c.patient(i)}]),
    "AppointmentResponse": lambda c, i: b(appointment=c.self_ref("Appointment", i),
                                          participantStatus="accepted", actor=c.patient(i)),
    # NOTE: AuditEvent is intentionally omitted -- Azure Health Data Services FHIR
    # rejects client PUT/POST of AuditEvent (HTTP 405 forbidden); it is a
    # server-managed resource type.
    "Basic": lambda c, i: b(code=_cc("Demo basic", "UMLCLREV"), subject=c.patient(i)),
    "BiologicallyDerivedProduct": lambda c, i: b(productCategory="tissue"),
    "BodyStructure": lambda c, i: b(patient=c.patient(i), location=_cc("Body site")),
    "ChargeItem": lambda c, i: b(status="billable", code=_cc("Office visit"),
                                 subject=c.patient(i)),
    "ChargeItemDefinition": lambda c, i: b(url=f"http://contoso.health/cid/{i}", status="active"),
    "Claim": lambda c, i: b(status="active", type=_cc("Professional", "professional",
                            "http://terminology.hl7.org/CodeSystem/claim-type"),
                            use="claim", patient=c.patient(i), created=DATE,
                            provider=c.organization(i), priority=_cc("normal", "normal",
                            "http://terminology.hl7.org/CodeSystem/processpriority"),
                            insurance=[{"sequence": 1, "focal": True,
                                        "coverage": c.self_ref("Coverage", i)}]),
    "ClaimResponse": lambda c, i: b(status="active", type=_cc("Professional", "professional",
                                    "http://terminology.hl7.org/CodeSystem/claim-type"),
                                    use="claim", patient=c.patient(i), created=DATE,
                                    insurer=c.organization(i), outcome="complete"),
    "ClinicalImpression": lambda c, i: b(status="completed", subject=c.patient(i)),
    "Communication": lambda c, i: b(status="completed", subject=c.patient(i)),
    "CommunicationRequest": lambda c, i: b(status="active", subject=c.patient(i)),
    "Composition": lambda c, i: b(status="final", type=_cc("Summary doc", "34133-9",
                                  "http://loinc.org"), date=TS, author=[c.practitioner(i)],
                                  title="Demo Composition"),
    "Consent": lambda c, i: b(status="active",
                              scope=_cc("Patient privacy", "patient-privacy",
                              "http://terminology.hl7.org/CodeSystem/consentscope"),
                              category=[_cc("Privacy", "59284-0", "http://loinc.org")],
                              patient=c.patient(i)),
    "Contract": lambda c, i: b(status="executed", subject=[c.patient(i)]),
    "Coverage": lambda c, i: b(status="active", beneficiary=c.patient(i),
                               payor=[c.organization(i)]),
    "CoverageEligibilityRequest": lambda c, i: b(status="active", purpose=["benefits"],
                                                 patient=c.patient(i), created=DATE,
                                                 insurer=c.organization(i)),
    "CoverageEligibilityResponse": lambda c, i: b(status="active", purpose=["benefits"],
                                                  patient=c.patient(i), created=DATE,
                                                  request=c.self_ref("CoverageEligibilityRequest", i),
                                                  outcome="complete", insurer=c.organization(i)),
    "DetectedIssue": lambda c, i: b(status="final", patient=c.patient(i)),
    "DeviceDefinition": lambda c, i: b(type=_cc("Demo device type")),
    "DeviceMetric": lambda c, i: b(type=_cc("Heart rate", "8867-4", "http://loinc.org"),
                                   category="measurement"),
    "DeviceRequest": lambda c, i: b(intent="order",
                                    codeCodeableConcept=_cc("Wheelchair", "58938008"),
                                    subject=c.patient(i)),
    "DeviceUseStatement": lambda c, i: b(status="active", subject=c.patient(i),
                                         device=c.device(i)),
    "DocumentManifest": lambda c, i: b(status="current",
                                       content=[c.self_ref("DocumentReference", i)],
                                       subject=c.patient(i)),
    "DocumentReference": lambda c, i: b(status="current", subject=c.patient(i),
                                        content=[{"attachment": {"contentType": "text/plain",
                                        "title": "Demo note"}}]),
    "Endpoint": lambda c, i: b(status="active",
                               connectionType=_coding("hl7-fhir-rest",
                               "http://terminology.hl7.org/CodeSystem/endpoint-connection-type"),
                               payloadType=[_cc("Any", "any",
                               "http://terminology.hl7.org/CodeSystem/endpoint-payload-type")],
                               address="https://contoso.health/fhir"),
    "EnrollmentRequest": lambda c, i: b(status="active", candidate=c.patient(i)),
    "EnrollmentResponse": lambda c, i: b(status="active",
                                         request=c.self_ref("EnrollmentRequest", i)),
    "EpisodeOfCare": lambda c, i: b(status="active", patient=c.patient(i)),
    "EventDefinition": lambda c, i: b(status="active",
                                      trigger=[{"type": "named-event", "name": "demo-event"}]),
    "Evidence": lambda c, i: b(status="active",
                               exposureBackground=c.self_ref("EvidenceVariable", i)),
    "EvidenceVariable": lambda c, i: b(status="active",
                                       characteristic=[{"definitionCodeableConcept":
                                       _cc("Adults over 18")}]),
    "ExplanationOfBenefit": lambda c, i: b(status="active", type=_cc("Professional", "professional",
                                           "http://terminology.hl7.org/CodeSystem/claim-type"),
                                           use="claim", patient=c.patient(i), created=DATE,
                                           insurer=c.organization(i), provider=c.organization(i),
                                           outcome="complete",
                                           insurance=[{"focal": True,
                                           "coverage": c.self_ref("Coverage", i)}]),
    "FamilyMemberHistory": lambda c, i: b(status="completed", patient=c.patient(i),
                                          relationship=_cc("Mother", "MTH",
                                          "http://terminology.hl7.org/CodeSystem/v3-RoleCode")),
    "Flag": lambda c, i: b(status="active", code=_cc("Allergy alert"), subject=c.patient(i)),
    "Goal": lambda c, i: b(lifecycleStatus="active", description=_cc("Lower A1c"),
                           subject=c.patient(i)),
    "Group": lambda c, i: b(type="person", actual=True, name="Demo Cohort"),
    "GuidanceResponse": lambda c, i: b(status="success",
                                       moduleCodeableConcept=_cc("Demo rule"),
                                       subject=c.patient(i)),
    "HealthcareService": lambda c, i: b(active=True, name="Demo Clinic Service",
                                        providedBy=c.organization(i)),
    "ImmunizationEvaluation": lambda c, i: b(status="completed", patient=c.patient(i),
                                             targetDisease=_cc("Influenza", "6142004"),
                                             immunizationEvent=c.immunization(i),
                                             doseStatus=_cc("Valid", "valid",
                                             "http://terminology.hl7.org/CodeSystem/immunization-evaluation-dose-status")),
    "ImmunizationRecommendation": lambda c, i: b(patient=c.patient(i), date=TS,
                                                 recommendation=[{"forecastStatus": _cc("Due", "due",
                                                 "http://terminology.hl7.org/CodeSystem/immunization-recommendation-status"),
                                                 "vaccineCode": [_cc("Influenza", "88")]}]),
    "InsurancePlan": lambda c, i: b(status="active", name="Demo Health Plan"),
    "Invoice": lambda c, i: b(status="issued", subject=c.patient(i)),
    "Library": lambda c, i: b(status="active", type=_cc("Logic library", "logic-library",
                              "http://terminology.hl7.org/CodeSystem/library-type")),
    "Linkage": lambda c, i: b(item=[{"type": "source", "resource": c.patient(i)},
                                    {"type": "alternate", "resource": c.patient(i + 1)}]),
    "List": lambda c, i: b(status="current", mode="snapshot", subject=c.patient(i)),
    "Measure": lambda c, i: b(status="active"),
    "MeasureReport": lambda c, i: b(status="complete", type="summary",
                                    measure="http://contoso.health/Measure/demo",
                                    period={"start": DATE, "end": DATE}),
    "Media": lambda c, i: b(status="completed",
                            content={"contentType": "image/png", "title": "Demo image"},
                            subject=c.patient(i)),
    "Medication": lambda c, i: b(code=_cc("Acetaminophen 325 MG", "313782", "http://www.nlm.nih.gov/research/umls/rxnorm")),
    "MedicationDispense": lambda c, i: b(status="completed",
                                         medicationCodeableConcept=_cc("Acetaminophen", "313782",
                                         "http://www.nlm.nih.gov/research/umls/rxnorm"),
                                         subject=c.patient(i)),
    "MedicationKnowledge": lambda c, i: b(status="active",
                                          code=_cc("Acetaminophen", "313782",
                                          "http://www.nlm.nih.gov/research/umls/rxnorm")),
    "MedicationStatement": lambda c, i: b(status="active",
                                          medicationCodeableConcept=_cc("Acetaminophen", "313782",
                                          "http://www.nlm.nih.gov/research/umls/rxnorm"),
                                          subject=c.patient(i)),
    "MessageHeader": lambda c, i: b(eventCoding=_coding("admin-notify",
                                    "http://example.org/fhir/message-events"),
                                    source={"endpoint": "https://contoso.health/fhir"}),
    "MolecularSequence": lambda c, i: b(coordinateSystem=0, patient=c.patient(i)),
    "NutritionOrder": lambda c, i: b(status="active", intent="order", patient=c.patient(i),
                                     dateTime=DATE),
    "ObservationDefinition": lambda c, i: b(code=_cc("Glucose", "2339-0", "http://loinc.org")),
    "OrganizationAffiliation": lambda c, i: b(active=True, organization=c.organization(i)),
    "PaymentNotice": lambda c, i: b(status="active", created=DATE,
                                    payment=c.self_ref("PaymentReconciliation", i),
                                    recipient=c.organization(i),
                                    amount={"value": 100, "currency": "USD"}),
    "PaymentReconciliation": lambda c, i: b(status="active", created=DATE, paymentDate=DATE,
                                            paymentAmount={"value": 100, "currency": "USD"}),
    "Person": lambda c, i: b(name=[{"family": "Demo", "given": ["Person"]}],
                             link=[{"target": c.patient(i)}]),
    "PlanDefinition": lambda c, i: b(status="active"),
    "PractitionerRole": lambda c, i: b(active=True, practitioner=c.practitioner(i),
                                       organization=c.organization(i)),
    "Provenance": lambda c, i: b(target=[c.patient(i)], recorded=TS,
                                 agent=[{"who": c.practitioner(i)}]),
    "Questionnaire": lambda c, i: b(status="active", title="Demo Questionnaire"),
    "QuestionnaireResponse": lambda c, i: b(status="completed", subject=c.patient(i)),
    "RelatedPerson": lambda c, i: b(patient=c.patient(i),
                                    name=[{"family": "Demo", "given": ["Relative"]}]),
    "RequestGroup": lambda c, i: b(status="active", intent="order", subject=c.patient(i)),
    "ResearchElementDefinition": lambda c, i: b(status="active", type="population",
                                                characteristic=[{"definitionCodeableConcept":
                                                _cc("Adults over 18")}]),
    "ResearchDefinition": lambda c, i: b(status="active",
                                         population=c.self_ref("ResearchElementDefinition", i)),
    "ResearchStudy": lambda c, i: b(status="active", title="Demo Research Study"),
    "ResearchSubject": lambda c, i: b(status="candidate", study=c.self_ref("ResearchStudy", i),
                                      individual=c.patient(i)),
    "RiskAssessment": lambda c, i: b(status="final", subject=c.patient(i)),
    "Schedule": lambda c, i: b(actor=[c.practitioner(i)]),
    "ServiceRequest": lambda c, i: b(status="active", intent="order",
                                     code=_cc("Lipid panel", "57698-3", "http://loinc.org"),
                                     subject=c.patient(i)),
    "Slot": lambda c, i: b(schedule=c.self_ref("Schedule", i), status="free",
                           start=TS, end="2024-01-15T10:30:00Z"),
    "Specimen": lambda c, i: b(type=_cc("Blood specimen", "119297000"), subject=c.patient(i)),
    "SpecimenDefinition": lambda c, i: b(typeCollected=_cc("Venous blood", "122555007")),
    "Substance": lambda c, i: b(code=_cc("Sodium chloride", "387390002")),
    "SupplyRequest": lambda c, i: b(status="active",
                                    itemCodeableConcept=_cc("Glucose test strips", "337388004"),
                                    quantity={"value": 50}),
    "Task": lambda c, i: b(status="completed", intent="order", **{"for": c.patient(i)}),
    "VerificationResult": lambda c, i: b(status="validated", target=[c.patient(i)]),
    "VisionPrescription": lambda c, i: b(status="active", created=DATE, patient=c.patient(i),
                                         dateWritten=DATE, prescriber=c.practitioner(i),
                                         lensSpecification=[{"product": _cc("Lens", "lens",
                                         "http://terminology.hl7.org/CodeSystem/ex-visionprescriptionproduct"),
                                         "eye": "right"}]),
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seed-dir", default=str(Path(__file__).parent / "fhir-seed"),
                    help="Folder of *.ndjson seed files (default: ./fhir-seed).")
    ap.add_argument("--count", type=int, default=8,
                    help="Instances to generate per resource type (default 8).")
    args = ap.parse_args()

    seed_dir = Path(args.seed_dir)
    seed_dir.mkdir(parents=True, exist_ok=True)

    anchors = _load_anchor_ids(seed_dir)
    missing = [t for t in _ANCHOR_TYPES if not anchors[t]]
    if missing:
        print(f"WARNING: no anchor ids found for {missing} "
              f"(references to those types will use synthesized ids)")

    ctx = Ctx(anchors, args.count)
    total = 0
    types_written = 0
    for rtype, builder in sorted(BUILDERS.items()):
        out = seed_dir / f"{rtype}.ndjson"
        lines = []
        for i in range(args.count):
            body = builder(ctx, i)
            res = {"resourceType": rtype, "id": _rid(rtype, i), **body}
            lines.append(json.dumps(res, separators=(",", ":")))
        out.write_text("\n".join(lines) + "\n", encoding="utf-8")
        total += len(lines)
        types_written += 1

    print(f"wrote {total} resources across {types_written} types into {seed_dir}")
    print("new types: " + ", ".join(sorted(BUILDERS)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

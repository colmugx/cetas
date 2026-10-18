import { describe, expect, test } from "bun:test";

import type { QuestionEventData } from "../events.ts";
import { QuestionActivityStore } from "./question-activity.ts";

function asked(overrides: Partial<QuestionEventData> = {}): QuestionEventData {
  return {
    question_id: "question-1",
    short_id: "@q1",
    origin_call: "call-1",
    question: "Which environment?",
    kind: "select",
    options: ["staging", "production"],
    asked_at: 1_000,
    deadline_at: 601_000,
    ...overrides,
  };
}

describe("QuestionActivityStore", () => {
  test("asked parks a question with its answer shape", () => {
    const store = new QuestionActivityStore(() => 5_000);
    expect(store.apply("question_asked", asked(), "s1")).toBe(true);
    const question = store.get("question-1");
    expect(question).toMatchObject({
      id: "question-1",
      short_id: "@q1",
      origin_call: "call-1",
      text: "Which environment?",
      kind: "select",
      options: ["staging", "production"],
      session: "s1",
    });
    expect(store.pendingFor("s1")).toHaveLength(1);
    expect(store.pendingFor("s2")).toHaveLength(0);
  });

  test("answered removes it and a replayed asked never revives it", () => {
    const store = new QuestionActivityStore();
    store.apply("question_asked", asked(), "s1");
    expect(store.apply("question_answered", asked(), "s1")).toBe(true);
    expect(store.get("question-1")).toBeUndefined();
    expect(store.apply("question_asked", asked(), "s1")).toBe(false);
    expect(store.pendingFor("s1")).toHaveLength(0);
    expect(store.size).toBe(0);
  });

  test("a plain reply closes the question without an answer event", () => {
    const store = new QuestionActivityStore();
    store.apply("question_asked", asked(), "s1");
    store.apply("question_asked", asked({ question_id: "question-2", short_id: "@q2" }), "s1");
    expect(store.apply("question_closed", asked({ question_id: "question-1" }), "s1")).toBe(true);
    expect(store.get("question-1")).toBeUndefined();
    expect(store.get("question-2")).toBeDefined();
    expect(store.apply("question_asked", asked(), "s1")).toBe(false);
  });

  test("a duplicate asked for a still-pending question is a no-op", () => {
    const store = new QuestionActivityStore();
    expect(store.apply("question_asked", asked(), "s1")).toBe(true);
    expect(store.apply("question_asked", asked({ question: "changed" }), "s1")).toBe(false);
    expect(store.get("question-1")?.text).toBe("Which environment?");
  });

  test("unknown labels and id-less payloads are ignored", () => {
    const store = new QuestionActivityStore();
    expect(store.apply("question_expired", asked(), "s1")).toBe(false);
    expect(store.apply("question_asked", undefined, "s1")).toBe(false);
    expect(store.apply("question_asked", asked({ question_id: "" }), "s1")).toBe(false);
    expect(store.size).toBe(0);
  });

  test("pending questions come back oldest ask first", () => {
    const store = new QuestionActivityStore();
    store.apply("question_asked", asked({ question_id: "question-2", asked_at: 2_000 }), "s1");
    store.apply("question_asked", asked({ question_id: "question-1", asked_at: 1_000 }), "s1");
    expect(store.pendingFor("s1").map((question) => question.id)).toEqual([
      "question-1",
      "question-2",
    ]);
  });

  test("expire drops questions past their deadline only", () => {
    const store = new QuestionActivityStore();
    store.apply("question_asked", asked(), "s1");
    store.apply(
      "question_asked",
      asked({ question_id: "question-2", short_id: "@q2", deadline_at: 0 }),
      "s1",
    );
    expect(store.expire(601_000)).toEqual([]);
    expect(store.expire(601_001)).toEqual(["question-1"]);
    expect(store.get("question-1")).toBeUndefined();
    // 0 disables expiry: the question stays answerable forever.
    expect(store.get("question-2")).toBeDefined();
  });

  test("withdraw settles questions so a replay cannot resurrect them", () => {
    const store = new QuestionActivityStore();
    store.apply("question_asked", asked(), "s1");
    store.apply("question_asked", asked({ question_id: "question-2" }), "s1");
    expect(store.withdraw("s1")).toBe(true);
    expect(store.size).toBe(0);
    expect(store.apply("question_asked", asked(), "s1")).toBe(false);
  });

  test("clear forgets everything, including the replay guards", () => {
    const store = new QuestionActivityStore();
    store.apply("question_asked", asked(), "s1");
    store.clear();
    expect(store.size).toBe(0);
    expect(store.apply("question_asked", asked(), "s1")).toBe(true);
  });
});

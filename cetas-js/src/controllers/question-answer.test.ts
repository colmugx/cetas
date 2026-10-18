import { describe, expect, test } from "bun:test";

import {
  answerFromText,
  answerResponseJson,
  parseAnswerArgument,
  parseQuestionAnswerPrefix,
} from "./question-answer.ts";

describe("parseQuestionAnswerPrefix", () => {
  test("recognizes a leading @qN and keeps the rest as the answer", () => {
    expect(parseQuestionAnswerPrefix("@q3 staging please")).toEqual({
      questionId: "question-3",
      text: "staging please",
    });
    expect(parseQuestionAnswerPrefix("  @q12  ")).toEqual({
      questionId: "question-12",
      text: "",
    });
  });

  test("leaves ordinary @path mentions alone", () => {
    expect(parseQuestionAnswerPrefix("@query.ts")).toBeUndefined();
    expect(parseQuestionAnswerPrefix("@q12abc")).toBeUndefined();
    expect(parseQuestionAnswerPrefix("look at @q1")).toBeUndefined();
    expect(parseQuestionAnswerPrefix("@q")).toBeUndefined();
  });
});

describe("parseAnswerArgument", () => {
  test("accepts the three id spellings", () => {
    expect(parseAnswerArgument("@q2 yes")?.questionId).toBe("question-2");
    expect(parseAnswerArgument("q2 yes")?.questionId).toBe("question-2");
    expect(parseAnswerArgument("question-2 yes")?.questionId).toBe("question-2");
    expect(parseAnswerArgument("question-2 yes")?.text).toBe("yes");
  });

  test("rejects text that does not address a question", () => {
    expect(parseAnswerArgument("")).toBeUndefined();
    expect(parseAnswerArgument("staging")).toBeUndefined();
    expect(parseAnswerArgument("@query x")).toBeUndefined();
  });
});

describe("answerFromText", () => {
  test("confirm understands yes/no words only", () => {
    expect(answerFromText("confirm", "yes", [])).toEqual({ confirm: true });
    expect(answerFromText("confirm", "NO", [])).toEqual({ confirm: false });
    expect(answerFromText("confirm", "maybe", [])).toBeUndefined();
  });

  test("select matches a label case-insensitively or a 0-based index", () => {
    const options = ["Staging", "Production"];
    expect(answerFromText("select", "production", options)).toEqual({ index: 1 });
    expect(answerFromText("select", "1", options)).toEqual({ index: 1 });
    expect(answerFromText("select", "5", options)).toBeUndefined();
    expect(answerFromText("select", "nowhere", options)).toBeUndefined();
  });

  test("input passes free text through and rejects empty", () => {
    expect(answerFromText("input", " node 22 ", [])).toEqual({ text: "node 22" });
    expect(answerFromText("input", "   ", [])).toBeUndefined();
  });
});

test("answerResponseJson is the bridge wire shape", () => {
  expect(answerResponseJson({ confirm: true })).toBe('{"confirm":true}');
  expect(answerResponseJson({ index: 1 })).toBe('{"index":1}');
  expect(answerResponseJson({ text: "a" })).toBe('{"text":"a"}');
});

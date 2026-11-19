import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import live_mcp
import meeting_trail


class MeetingTrailTests(unittest.TestCase):
    def test_answer_preserves_paragraphs(self):
        self.assertEqual(meeting_trail.answer_text("---\n**Erster Punkt.**\n\n\nZweiter Punkt."),
                         "Erster Punkt.\n\nZweiter Punkt.")

    def test_scoped_mcp_cannot_list_or_read_another_recording(self):
        bound = "2026-11-18T15:00:01"
        other = "2026-11-18T15:00:02"
        reader = live_mcp.Reader(".", ".", note_recording=bound)
        reader.live_status = lambda: {"live_status": "recording", "active_recording_id": other}
        status = reader.call("list_recordings", {})
        self.assertEqual(status["live_status"], "idle")
        self.assertIsNone(status["active_recording_id"])
        self.assertEqual(reader.call("read_transcript", {"recording_id": bound})["status"], "not_active")
        for name in ["read_transcript", "read_chat"]:
            with self.assertRaises(live_mcp.ReadError):
                reader.call(name, {"recording_id": other})
        self.assertIn("No background polling", live_mcp.CONVERSATION)
        self.assertNotIn("No background polling", live_mcp.NOTE_CONVERSATION)

    def test_updates_share_luna_session_and_workspace_with_separate_sol_session(self):
        rid = "2026-11-18T15:00:01"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            project = root / "Projekt.md"
            project.touch()
            workspace = root / "workspace"
            workspace.mkdir()
            (workspace / "Glossar.md").write_text("## Glossar\nKennwort: BIRKE\n## Andere\nFremd")
            config = {"stateRoot": root / "private", "vault": root, "name": "Alex",
                      "macHost": "mac", "macReader": "/mac/live_mcp.py",
                      "projects": {"Probe": {"note": "Projekt.md", "cwd": str(workspace),
                                             "workspaceID": "wks_0123456789", "glossary": "Glossar.md",
                                             "glossaryHeading": "Glossar"}}}
            requests = []
            active = True
            phase = 1

            def source(config, scoped, name, args):
                self.assertEqual(scoped, rid)
                if name == "list_recordings":
                    return {"live_status": "recording" if active else "idle",
                            "active_recording_id": rid if active else None}
                events = [{"kind": "segment", "start": phase * 50, "track": "system",
                           "text": "Wir müssen entscheiden." if phase == 1 else "Alex, weiter."}]
                return {"status": "ok", "recording_id": rid, "cursor": str(phase), "has_more": False,
                        "events": events if args["cursor"] != str(phase) else []}

            def luna(request):
                requests.append(request)
                answer = "---\n**Runde Markierung.**" if request["role"] == "question" else json.dumps({
                    "topic": {"title": f"Thema {phase}", "points": ["Punkt"], "new": True},
                    "decisionPending": phase == 1, "decisions": ["Runde Markierung.", "Skizze"], "tasks": ["Skizze."]
                })
                return {"answer": answer, "sessionID": request["conversationID"]}

            def operation(op, **kwargs):
                return meeting_trail.operate(config, {"op": op, "project": "Probe", "recordingID": rid,
                                                      **kwargs}, source=source, luna=luna)

            with patch.object(meeting_trail, "open_pull_requests", return_value=["#8 Test PR"]) as prs:
                first = operation("tick", title="Testtermin")
            self.assertTrue(first["note"]["hasProjectContext"])
            self.assertEqual(first["note"]["contextLabel"], "Probe / Glossar / 1 PR")
            self.assertEqual(first["note"]["meetingTitle"], "Testtermin")
            prs.assert_called_once()
            self.assertNotIn("projectContext", first["note"])
            self.assertEqual(first["note"]["decisions"], ["Runde Markierung."])
            self.assertEqual(first["note"]["hint"], "Eine Entscheidung steht an")
            operation("tick")
            self.assertEqual(len(requests), 1)
            phase = 2
            second = operation("tick")
            self.assertEqual(len(second["note"]["topics"]), 2)
            self.assertEqual(second["note"]["hint"], "Dein Name ist gefallen")
            key = str(uuid.uuid4())
            answer = operation("ask", requestID=key, question="Welche Markierung?")
            self.assertEqual(answer, operation("ask", requestID=key, question="Welche Markierung?"))
            self.assertEqual(answer["answer"], "Runde Markierung.")
            self.assertEqual(requests[0]["conversationID"], requests[1]["conversationID"])
            self.assertNotEqual(requests[0]["conversationID"], requests[2]["conversationID"])
            self.assertTrue(all(request["workspaceID"] == "wks_0123456789" for request in requests))
            self.assertIn("--question-recording", requests[2]["mcp"]["args"])
            self.assertIn("--vault-note", requests[2]["mcp"]["args"])
            self.assertIn("BIRKE", requests[1]["prompt"])
            self.assertIn("#8 Test PR", requests[1]["prompt"])
            self.assertEqual(len(requests), 3)
            self.assertTrue(operation("finish")["waiting"])
            active = False
            self.assertTrue(operation("finish")["note"]["recapSaved"])
            self.assertTrue(operation("finish")["note"]["ended"])
            operation("tick")
            self.assertEqual(len(requests), 3)
            self.assertEqual(project.read_text().count("<!-- mitschrift-gespraechsspur:"), 1)
            self.assertFalse(any(p.name.endswith(".json") for p in root.iterdir()))

    def test_discard_does_not_append_recap(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = {"stateRoot": root / "private"}
            result = meeting_trail.operate(config, {"op": "discard", "recordingID": "2026-11-18T15:00:08"},
                                           source=lambda *args: self.fail("discard must not fetch a transcript"),
                                           luna=lambda *args: self.fail("discard must not start a model"))
            self.assertTrue(result["note"]["ended"])
            self.assertFalse(result["note"]["recapSaved"])

    def test_paths_inside_a_repo_are_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            (repo / ".git").mkdir()
            with self.assertRaises(ValueError):
                meeting_trail.outside_repo(repo / "data")


if __name__ == "__main__":
    unittest.main()

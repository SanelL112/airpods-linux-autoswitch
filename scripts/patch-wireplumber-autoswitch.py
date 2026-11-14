#!/usr/bin/env python3
"""Patch WirePlumber's autoswitch-bluetooth-profile.lua to traverse PipeWire node.group DSP pipelines (e.g. EasyEffects)."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

DEFAULT_INPUT = Path("/usr/share/wireplumber/scripts/device/autoswitch-bluetooth-profile.lua")
DEFAULT_OUTPUT = (
    Path.home()
    / ".local/share/wireplumber/scripts/device/autoswitch-bluetooth-profile.lua"
)

OLD_GRAPH_FUNC = """function getLinkedBluetoothLoopbackSourceNodeForStream (stream, node_om, link_om, visited_link_groups)
  local stream_id = stream["bound-id"]

  -- Make sure the node is linked
  local link = link_om:lookup {
    Constraint { "link.input.node", "=", stream_id, type = "pw-global"}
  }
  if link == nil then
    return nil
  end
  local peer_id = link.properties["link.output.node"]

  -- If the peer node is the BT loopback source node, return its Id.
  -- Otherwise recursively advance in the graph if it is linked to a filter.
  local bt_node = node_om:lookup {
      Constraint { "media.class", "matches", "Audio/Source", type = "pw-global" },
      Constraint { "bound-id", "=", peer_id, type = "gobject" },
      Constraint { "bluez5.loopback", "=", "true", type = "pw" }
  }
  if bt_node ~= nil then
    return bt_node
  else
    local filter_main_node = node_om:lookup {
      Constraint { "bound-id", "=", peer_id, type = "gobject" },
      Constraint { "node.link-group", "+", type = "pw" }
    }
    if filter_main_node ~= nil then
      local filter_link_group = filter_main_node.properties ["node.link-group"]
      if visited_link_groups == nil then
        visited_link_groups = {}
      end
      if visited_link_groups [filter_link_group] then
        return nil
      else
        visited_link_groups [filter_link_group] = true
      end
      for filter_stream_node in node_om:iterate {
          Constraint { "bound-id", "!", peer_id, type = "gobject" },
          Constraint { "stream.monitor", "!", "true", type = "pw" },
          Constraint { "bluez5.loopback", "!", "true", type = "pw" },
          Constraint { "node.link-group", "=", filter_link_group, type = "pw" }
        } do
        local bt_node = getLinkedBluetoothLoopbackSourceNodeForStream (filter_stream_node, node_om, link_om, visited_link_groups)
        if bt_node ~= nil then
          return bt_node
        end
      end
    end
  end

  return nil
end"""

NEW_GRAPH_FUNC = """function isIntermediateGroupNode (node)
  if node == nil then
    return false
  end
  local mc = node.properties["media.class"]
  local role = node.properties["media.role"]
  return mc == "Audio/Source/Virtual" or role == "DSP" or mc == "" or mc == nil
end

function getLinkedBluetoothLoopbackSourceNodeForStream (stream, node_om, link_om, visited_link_groups, visited_nodes)
  local stream_id = stream["bound-id"]
  if visited_nodes == nil then
    visited_nodes = {}
  end

  local seen_peers = {}
  for link in link_om:iterate {
    Constraint { "link.input.node", "=", stream_id, type = "pw-global"}
  } do
    local peer_id = link.properties["link.output.node"]
    if peer_id ~= nil and not seen_peers[tostring(peer_id)] then
      seen_peers[tostring(peer_id)] = true

      -- If the peer node is the BT loopback source node, return it.
      -- Otherwise recursively advance in the graph if it is linked to a filter
      -- or DSP/virtual-source pipeline (e.g., EasyEffects ee_source_group).
      local bt_node = node_om:lookup {
          Constraint { "media.class", "matches", "Audio/Source", type = "pw-global" },
          Constraint { "bound-id", "=", peer_id, type = "gobject" },
          Constraint { "bluez5.loopback", "=", "true", type = "pw" }
      }
      if bt_node ~= nil then
        return bt_node
      end

      local filter_main_node = node_om:lookup {
        Constraint { "bound-id", "=", peer_id, type = "gobject" },
        Constraint { "node.link-group", "+", type = "pw" }
      }
      if filter_main_node ~= nil then
        local filter_link_group = filter_main_node.properties ["node.link-group"]
        if visited_link_groups == nil then
          visited_link_groups = {}
        end
        if not visited_link_groups [filter_link_group] then
          visited_link_groups [filter_link_group] = true
          for filter_stream_node in node_om:iterate {
              Constraint { "bound-id", "!", peer_id, type = "gobject" },
              Constraint { "stream.monitor", "!", "true", type = "pw" },
              Constraint { "bluez5.loopback", "!", "true", type = "pw" },
              Constraint { "node.link-group", "=", filter_link_group, type = "pw" }
            } do
            local linked_bt = getLinkedBluetoothLoopbackSourceNodeForStream (
                filter_stream_node, node_om, link_om, visited_link_groups, visited_nodes)
            if linked_bt ~= nil then
              return linked_bt
            end
          end
        end
      end

      local peer_key = tostring(peer_id)
      if not visited_nodes[peer_key] then
        visited_nodes[peer_key] = true
        local group_node = node_om:lookup {
          Constraint { "bound-id", "=", peer_id, type = "gobject" },
          Constraint { "stream.monitor", "!", "true", type = "pw" },
          Constraint { "bluez5.loopback", "!", "true", type = "pw" },
          Constraint { "node.group", "+", type = "pw" }
        }
        if isIntermediateGroupNode (group_node) then
          local linked_bt = getLinkedBluetoothLoopbackSourceNodeForStream (
              group_node, node_om, link_om, visited_link_groups, visited_nodes)
          if linked_bt ~= nil then
            return linked_bt
          end
        end
      end
    end
  end

  return nil
end"""

OLD_LINK_HOOK = """    local bt_node = node_om:lookup {
      Constraint { "media.class", "matches", "Audio/Source", type = "pw-global" },
      Constraint { "bluez5.loopback", "=", "true", type = "pw" },
      Constraint { "bound-id", "=", out_node_id, type = "gobject" },
    }
    if stream ~= nil or bt_node ~= nil then
      capture_stream_links [link.id] = true
      source:call ("push-event", "evaluate-bluetooth-profiles", nil, nil)
    end"""

NEW_LINK_HOOK = """    local bt_node = node_om:lookup {
      Constraint { "media.class", "matches", "Audio/Source", type = "pw-global" },
      Constraint { "bluez5.loopback", "=", "true", type = "pw" },
      Constraint { "bound-id", "=", out_node_id, type = "gobject" },
    }
    -- Intermediate DSP/virtual nodes (e.g. EasyEffects ee_source_group) may link
    -- after bt_node -> DSP is added, so re-evaluate once internal links complete.
    local group_node = node_om:lookup {
      Constraint { "bound-id", "=", in_stream_id, type = "gobject" },
      Constraint { "stream.monitor", "!", "true", type = "pw" },
      Constraint { "bluez5.loopback", "!", "true", type = "pw" },
      Constraint { "node.group", "+", type = "pw" },
    }
    if stream ~= nil or bt_node ~= nil or isIntermediateGroupNode (group_node) then
      capture_stream_links [link.id] = true
      source:call ("push-event", "evaluate-bluetooth-profiles", nil, nil)
    end"""


def patch_lua(text: str) -> str:
    """Apply node.group traversal and link_added_hook patch idempotently."""
    if NEW_GRAPH_FUNC in text and NEW_LINK_HOOK in text:
        return text

    if OLD_GRAPH_FUNC not in text:
        raise ValueError(
            "Upstream getLinkedBluetoothLoopbackSourceNodeForStream block did not match"
        )
    if OLD_LINK_HOOK not in text:
        raise ValueError("Upstream link_added_hook block did not match")

    return text.replace(OLD_GRAPH_FUNC, NEW_GRAPH_FUNC, 1).replace(
        OLD_LINK_HOOK, NEW_LINK_HOOK, 1
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--stdout", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not args.input.is_file():
        print(f"error: input file not found: {args.input}", file=sys.stderr)
        return 1

    patched = patch_lua(args.input.read_text(encoding="utf-8"))

    if args.stdout or args.dry_run:
        if args.dry_run and not args.stdout:
            print(f"[dry-run] Patch verified against {args.input}; would write {args.output}")
        else:
            sys.stdout.write(patched)
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(patched, encoding="utf-8")
    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

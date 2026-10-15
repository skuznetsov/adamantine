local selected = editor.context and editor.context.selected_buffer
if type(selected) ~= "table" or
   type(selected.buffer_id) ~= "string" or selected.buffer_id == "" or
   type(selected.revision) ~= "string" or selected.revision == "" then
  print("No reviewed selected buffer is available")
  return
end

local requested_start_line = 1
local requested_line_count = 64
local result = editor.call("editor.read_buffer", {
  buffer_id = selected.buffer_id,
  revision = selected.revision,
  start_line = requested_start_line,
  line_count = requested_line_count,
  start_column = 0,
  max_columns = 160,
})
if result.status ~= "ok" then
  print("Selected-buffer read failed: " .. (result.message or result.status or "unknown error"))
  return
end

local data = result.data
if type(data) ~= "table" or type(data.lines) ~= "table" then
  print("Selected-buffer read returned an incomplete result")
  return
end
if data.buffer_id ~= selected.buffer_id or
   data.revision ~= selected.revision or
   data.start_line ~= requested_start_line or
   type(data.complete) ~= "boolean" or
   type(data.partial) ~= "boolean" or
   data.complete == data.partial then
  print("Selected-buffer read returned inconsistent receipt or completion metadata")
  return
end

local report = {}
local function add_report_line(text)
  report[#report + 1] = text
end

add_report_line("Approved buffer: " .. tostring(data.buffer_id) .. " revision " .. tostring(data.revision))
add_report_line("Project-relative path: " .. tostring(data.path) .. "; first line: " .. tostring(data.start_line))
add_report_line("Safe full-line spans are same-line and half-open. Preserve leading indentation in new_text; do not add a newline.")
local span_sequence_trusted = true
local last_requested_line = requested_start_line + requested_line_count - 1
for row_index, line in ipairs(data.lines) do
  local expected_line = requested_start_line + row_index - 1
  if type(line) ~= "table" then
    span_sequence_trusted = false
    add_report_line("Row " .. tostring(row_index) .. ": [invalid line metadata]")
  else
    local line_number = line.line
    local row_in_sequence = type(line_number) == "number" and
      line_number % 1 == 0 and line_number == expected_line and
      line_number >= requested_start_line and line_number <= last_requested_line
    if not row_in_sequence then
      span_sequence_trusted = false
    end

    local complete = line.complete == true
    local marker = complete and "" or " [partial line; trailing columns not included]"
    add_report_line(tostring(line_number) .. ": " .. tostring(line.text) .. marker)

    local start_column = line.start_column
    local end_column = line.end_column
    if span_sequence_trusted and row_in_sequence and complete and
       type(line.text) == "string" and
       type(start_column) == "number" and start_column == 0 and
       type(end_column) == "number" and end_column >= 0 and end_column <= 160 and end_column % 1 == 0 then
      add_report_line("Span: start_line=" .. tostring(line_number) ..
        ",start_column=0,end_line=" .. tostring(line_number) ..
        ",end_column=" .. tostring(end_column))
    end
  end
end

if data.partial then
  local continuation = data.continuation
  if type(continuation) == "table" then
    add_report_line("Read is partial; next fragment begins at line " .. tostring(continuation.start_line) ..
      ", column " .. tostring(continuation.start_column) .. ".")
  else
    add_report_line("Read is partial; source beyond the displayed fragment was not included.")
  end
else
  add_report_line("Read complete within the 64-line and 160-column-per-line bounds.")
end

print(table.concat(report, "\n"))

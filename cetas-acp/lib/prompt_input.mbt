///|
/// ACP prompt content → Posoco user message. `Text` and `Image` map
/// one-to-one; other v1 blocks degrade to text annotations (embedded blobs
/// and audio are dropped — those capabilities are not advertised).

///|
pub fn acp_prompt_to_message(
  prompt : Array[@acp.ContentBlock],
) -> @posoco.Message {
  let content : Array[@posoco.Content] = []
  for block in prompt {
    match block {
      Text(text) => content.push(@posoco.Content::Text(text.text))
      Image(image) =>
        content.push(
          @posoco.Content::Image(media_type=image.mime_type, data=image.data),
        )
      Audio(_) => ()
      ResourceLink(link) =>
        content.push(@posoco.Content::Text("Resource: \{link.uri}"))
      Resource(embedded) =>
        match embedded.resource {
          Text(text_resource) =>
            content.push(@posoco.Content::Text(text_resource.text))
          Blob(_) => ()
        }
    }
  }
  @posoco.Message::UserMessage(content~)
}

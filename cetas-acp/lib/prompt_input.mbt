///|
/// ACP prompt content → Posoco user message.
///
/// `Text` and `Image` map one-to-one (the endpoint advertises
/// `prompt_image`). The remaining v1 blocks degrade to text annotations the
/// model can read: linked resources keep their uri, and embedded text
/// resources inline their content. Embedded blobs and audio are dropped —
/// neither capability is advertised, and a client that respects
/// capabilities never sends them.

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

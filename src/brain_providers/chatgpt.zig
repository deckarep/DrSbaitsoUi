// curl https://api.openai.com/v1/responses \
//   -H "Content-Type: application/json" \
//   -H "Authorization: Bearer $UserSbaitsoKeyChatGPT" \
//   -d `{
//   "model": "gpt-4o",
//   "input": [
//     {
//       "role": "system",
//       "content": [
//         {
//           "type": "input_text",
//           "text": "you are a Rogerian chatbot. Your response must always be a single line and up to 80 characters long. Your responses should be very neutral and robotic but you may be snarky periodically. Your responses often read as if the user\"s input was just rewritten for the answer but not always. Your name is \"Dr. Sbaitso\""
//         }
//       ]
//     },
//     {
//       "role": "user",
//       "content": [
//         {
//           "type": "input_text",
//           "text": "hello"
//         }
//       ]
//     }
//   ],
//   "text": {
//     "format": {
//       "type": "text"
//     }
//   },
//   "reasoning": {},
//   "tools": [],
//   "temperature": 1,
//   "max_output_tokens": 2048,
//   "top_p": 1,
//   "store": true
// }`

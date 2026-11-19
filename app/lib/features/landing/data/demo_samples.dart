/// Sample content for the landing page's answer demo.
///
/// Everything in this file is fictional. It exists only to show how an answer
/// links back to the passages it came from. Nothing here does any I/O.
class DemoPassage {
  /// Text before the cited part of the passage.
  final String before;

  /// The cited part. Highlighted when the selected claim uses this passage.
  final String hit;

  /// Text after the cited part.
  final String after;

  /// Indexes of the claims (in [DemoQuestion.claims]) that rely on [hit].
  final List<int> claims;

  const DemoPassage({
    required this.before,
    this.hit = '',
    this.after = '',
    this.claims = const [],
  });
}

class DemoSource {
  final String name;
  final String where;
  final List<DemoPassage> passages;

  const DemoSource({
    required this.name,
    required this.where,
    required this.passages,
  });
}

class DemoClaim {
  /// Each chain reads left to right: a file, what it says, the fact it gives.
  final List<List<String>> chains;

  /// One plain sentence on how the claim was reached.
  final String note;

  const DemoClaim({required this.chains, required this.note});
}

class DemoSegment {
  final String text;

  /// Index into [DemoQuestion.claims], or null for plain text.
  final int? claim;

  const DemoSegment(this.text, {this.claim});
}

class DemoQuestion {
  final String question;
  final List<DemoSegment> segments;
  final List<DemoClaim> claims;
  final List<DemoSource> sources;

  const DemoQuestion({
    required this.question,
    required this.segments,
    required this.claims,
    required this.sources,
  });
}

const List<DemoQuestion> kDemoQuestions = [
  DemoQuestion(
    question: 'What date do I need to give notice by to move out on March 31?',
    segments: [
      DemoSegment('Give written notice by '),
      DemoSegment('January 30', claim: 0),
      DemoSegment('. Your lease asks for '),
      DemoSegment('60 days of written notice', claim: 1),
      DemoSegment(", and your landlord's email on November 3 confirmed "),
      DemoSegment('a March 31 move-out', claim: 2),
      DemoSegment('.'),
    ],
    claims: [
      DemoClaim(
        chains: [
          ['landlord-email.txt', 'move-out', 'March 31'],
          ['lease.pdf, page 4', 'notice period', '60 days'],
        ],
        note:
            'Neither file states this date. Counting back 60 days from March 31 gives January 30.',
      ),
      DemoClaim(
        chains: [
          ['lease.pdf, page 4', 'notice period', '60 days'],
        ],
        note: 'Stated directly in the lease.',
      ),
      DemoClaim(
        chains: [
          ['landlord-email.txt', 'move-out', 'March 31'],
        ],
        note: 'Stated directly in the email.',
      ),
    ],
    sources: [
      DemoSource(
        name: 'lease.pdf',
        where: 'Page 4, Ending the lease',
        passages: [
          DemoPassage(
            before:
                'The tenant may end this lease at the close of the initial term by giving the landlord ',
            hit: "sixty (60) days' written notice",
            after: '.',
            claims: [0, 1],
          ),
          DemoPassage(
            before: 'Rent is due on the first day of each month.',
          ),
        ],
      ),
      DemoSource(
        name: 'landlord-email.txt',
        where: 'Nov 3, Re: Moving out',
        passages: [
          DemoPassage(
            before: "Thanks for letting me know. I've noted ",
            hit: 'your move-out for March 31',
            after: ", and I'll book the walkthrough for that morning.",
            claims: [0, 2],
          ),
        ],
      ),
    ],
  ),
  DemoQuestion(
    question: 'Does a final exam land on the same day as a project deadline?',
    segments: [
      DemoSegment('Yes. On '),
      DemoSegment('December 16', claim: 0),
      DemoSegment(', the '),
      DemoSegment('Databases final is at 9:00 am', claim: 1),
      DemoSegment(' and the '),
      DemoSegment('Operating Systems project is due at 11:59 pm', claim: 2),
      DemoSegment('.'),
    ],
    claims: [
      DemoClaim(
        chains: [
          ['databases-syllabus.pdf', 'final exam', 'Dec 16'],
          ['os-syllabus.pdf', 'project due', 'Dec 16'],
        ],
        note: 'Two items in two courses share the same date.',
      ),
      DemoClaim(
        chains: [
          ['databases-syllabus.pdf', 'final exam', 'Dec 16, 9:00 am'],
        ],
        note: 'Stated directly in the Databases syllabus.',
      ),
      DemoClaim(
        chains: [
          ['os-syllabus.pdf', 'project due', 'Dec 16, 11:59 pm'],
        ],
        note: 'Stated directly in the Operating Systems syllabus.',
      ),
    ],
    sources: [
      DemoSource(
        name: 'databases-syllabus.pdf',
        where: 'Page 1, Assessment',
        passages: [
          DemoPassage(
            before: 'Final exam: ',
            hit: 'Wednesday, December 16, 9:00 to 11:00 am',
            after: '. Closed book.',
            claims: [0, 1],
          ),
        ],
      ),
      DemoSource(
        name: 'os-syllabus.pdf',
        where: 'Page 3, Schedule',
        passages: [
          DemoPassage(
            before: 'Final project due ',
            hit: 'Wednesday, December 16, 11:59 pm',
            after: '.',
            claims: [0, 2],
          ),
        ],
      ),
      DemoSource(
        name: 'academic-calendar.pdf',
        where: 'Page 1',
        passages: [
          DemoPassage(before: 'Finals week runs December 14 to 18.'),
        ],
      ),
    ],
  ),
  DemoQuestion(
    question: 'Who is reviewing the budget, and by when?',
    segments: [
      DemoSegment('Mina', claim: 0),
      DemoSegment(' is reviewing it. She took the action in '),
      DemoSegment('the November 12 team meeting', claim: 1),
      DemoSegment(', and her email on November 16 promised comments '),
      DemoSegment('by Friday, November 20', claim: 2),
      DemoSegment('.'),
    ],
    claims: [
      DemoClaim(
        chains: [
          ['meeting-notes-nov-12.md', 'action owner', 'Mina'],
        ],
        note: 'Named in the meeting notes.',
      ),
      DemoClaim(
        chains: [
          ['meeting-notes-nov-12.md', 'action', 'Review the Q1 budget draft'],
        ],
        note: 'Stated directly in the meeting notes.',
      ),
      DemoClaim(
        chains: [
          ['mina-email.txt', 'promise', 'Comments by Friday the 20th'],
        ],
        note:
            'The email is dated November 16, so "Friday the 20th" is November 20.',
      ),
    ],
    sources: [
      DemoSource(
        name: 'meeting-notes-nov-12.md',
        where: 'Team meeting, action items',
        passages: [
          DemoPassage(
            before: 'Action: ',
            hit: 'Mina reviews the Q1 budget draft',
            after: '.',
            claims: [0, 1],
          ),
          DemoPassage(before: 'Next meeting: December 3.'),
        ],
      ),
      DemoSource(
        name: 'mina-email.txt',
        where: 'Nov 16, Re: Budget draft',
        passages: [
          DemoPassage(
            before: "Hi Jorge, I'll send my comments ",
            hit: 'by Friday the 20th',
            after: '.',
            claims: [2],
          ),
        ],
      ),
    ],
  ),
];

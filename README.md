
<h1 align="center">Agent Sessions</h1>

**A native macOS app for browsing your local Claude Code sessions.**

Read, search, tag, and resume any past session plus a Findings tab that scans your transcripts for leaked secrets. Everything runs locally; no data leaves your machine.

<img width="2554" height="1332" alt="image" src="https://github.com/user-attachments/assets/e4afdabe-0d33-49a2-a7a6-4cac32764334" />

> Author: [Divyanshu](linkedin.com/in/iamdivyanshu)

## What you get

- Browse every local Claude Code session, searchable by title, transcript text, or tag
- Resume any session straight into Terminal
- Live token/cost usage per session and per day
- Findings tab — local secret scanning across your history, with a triage status per finding (unclassified / true positive / benign positive / false positive)

## Build & run

> - Requires macOS 13+ and Swift 5.9+.
> - Might require sudo permission to move to `Applications`

```bash
git clone https://github.com/peachycloudsecurity/AgentSessions.git
cd AgentSessions
./scripts/package_app.sh
```

This builds the app and installs it into `/Applications`, so it shows up in Spotlight/Launchpad like any other app.

## License

GPL-3.0 - see [LICENSE](LICENSE).

## Disclaimer

- The information, commands, and demonstrations presented in this lab including any course, are intended strictly for educational purposes. Under no circumstances should they be used to compromise or attack any system outside the boundaries of this educational session unless explicit permission has been granted.

    - <b>This course is provided by the instructors independently and is not endorsed by their employers or any other corporate entity. The content does not necessarily reflect the views or policies of any company or professional organization associated with the instructors.</b>

- **Usage of Training Material**: The training material is provided without warranties or guarantees. Participants are responsible for applying the techniques or methods discussed during the training. The trainers and their respective employers or affiliated companies are not liable for any misuse or misapplication of the information provided.

- **Liability**: The trainers, their employers, and any affiliated companies are not responsible for any direct, indirect, incidental, or consequential damages arising from the use of the information provided in this course. No responsibility is assumed for any injury or damage to persons, property, or systems as a result of using or operating any methods, products, instructions, or ideas discussed during the training.

- **Intellectual Property**: This course and all accompanying materials, including slides, worksheets, and documentation, are the intellectual property of the trainers. They are shared under the GPL-3.0 license, which requires that appropriate credit be given to the trainers whenever the materials are used, modified, or redistributed.

- **References**: Some of the labs referenced in this workshop are based on open-source material. Additionally, modifications and fixes have been applied using AI tools such as Amazon Q, ChatGPT, and Gemini.

- **Educational Purpose**: This lab is for educational purposes only. Do not attack or test any website or network without proper authorization. The trainers are not liable or responsible for any misuse.
- **Usage Rights**: Individuals are permitted to use this course for instructional purposes, provided that no fees are charged to the students.



### By: **[Peachycloud Security](https://peachycloudsecurity.com)**


<p align="center">
  by <a href="https://topmate.io/peachycloudsecurity">Anjali &amp; Divyanshu</a> (theshukladuo) at <a href="https://www.youtube.com/@peachycloudsecurity">Peachycloud Security </a>
</p>


## 💝 Support the Project

Your support helps us maintain and improve this workshop, create more educational content, and continue building open-source security resources for the community.

**Ways to Support:**
- **Subscribe on YouTube** - [youtube.com/@peachycloudsecurity](https://www.youtube.com/@peachycloudsecurity)
- **Sponsor via GitHub** - [GitHub Sponsors](https://github.com/sponsors/peachycloudsecurity)
- **Explore Learning Resources** - Access additional tutorials, walkthroughs, and hands-on labs at [peachycloudsecurity.com](https://peachycloudsecurity.com)
- **Connect & Learn** - Connect with us via [Topmate](https://topmate.io/peachycloudsecurity)

> **Looking for personalized guidance?** Get one-on-one mentorship, interview prep, or custom training sessions through our [Topmate](https://topmate.io/peachycloudsecurity) platform.


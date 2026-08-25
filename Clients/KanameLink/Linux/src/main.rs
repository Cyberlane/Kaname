use gtk::gdk::Display;
use gtk::prelude::*;
use gtk::{
    AccessibleRole, Align, Application, ApplicationWindow, Box as GtkBox, Button, CssProvider,
    Entry, Image, Label, ListBox, ListBoxRow, Orientation, Paned, ScrolledWindow, SelectionMode,
    TextView, WrapMode,
};
use kaname_link_linux::{
    CoreClient, LinkConnectionStatus, LinkDiscussion, LinkHostVerificationState, LinkSnapshot,
    LinkSpace, LinkStatusPresentation, synthetic_snapshot,
};
use std::cell::RefCell;
use std::env;
use std::rc::Rc;

fn main() {
    let application = Application::builder()
        .application_id("com.cyberlane.KanameLink")
        .build();
    application.connect_activate(build_ui);
    application.run();
}

fn build_ui(application: &Application) {
    install_css();
    let synthetic = env::var("KANAME_LINK_SYNTHETIC_PREVIEW").as_deref() == Ok("1");
    let client = if synthetic {
        None
    } else {
        CoreClient::discover().ok().map(Rc::new)
    };
    let snapshot = if synthetic {
        synthetic_snapshot()
    } else {
        client
            .as_ref()
            .and_then(|client| client.snapshot().ok())
            .unwrap_or_else(core_unavailable_snapshot)
    };

    let window = ApplicationWindow::builder()
        .application(application)
        .title("Kaname Link")
        .default_width(1_180)
        .default_height(760)
        .build();
    let root = GtkBox::new(Orientation::Vertical, 0);
    if synthetic {
        let banner = Label::new(Some(
            "Synthetic preview · no real collaborator data or connection",
        ));
        banner.add_css_class("preview-banner");
        banner.set_margin_top(6);
        banner.set_margin_bottom(6);
        root.append(&banner);
    }
    let content = GtkBox::new(Orientation::Vertical, 0);
    content.set_vexpand(true);
    root.append(&content);
    render_content(&content, snapshot, client, synthetic, None);
    window.set_child(Some(&root));
    window.present();
}

fn render_content(
    container: &GtkBox,
    snapshot: LinkSnapshot,
    client: Option<Rc<CoreClient>>,
    synthetic: bool,
    notice: Option<String>,
) {
    clear(container);
    if snapshot
        .connection_status()
        .capabilities()
        .can_request_enrollment
    {
        render_enrollment(container, client, notice);
    } else {
        render_workspace(container, snapshot, client, synthetic, notice);
    }
}

fn render_enrollment(
    container: &GtkBox,
    client: Option<Rc<CoreClient>>,
    initial_notice: Option<String>,
) {
    let panel = GtkBox::new(Orientation::Vertical, 14);
    panel.add_css_class("enrollment-panel");
    panel.set_halign(Align::Center);
    panel.set_valign(Align::Center);
    panel.set_size_request(620, -1);
    panel.set_margin_start(32);
    panel.set_margin_end(32);
    panel.set_margin_top(32);
    panel.set_margin_bottom(32);

    let title = Label::new(Some("Connect to a Kaname Link host"));
    title.add_css_class("title");
    title.set_halign(Align::Start);
    panel.append(&title);
    let explanation = Label::new(Some(
        "Paste the complete invitation artifact shared by the host. It contains a single-use secret and should be handled privately.",
    ));
    explanation.set_wrap(true);
    explanation.set_xalign(0.0);
    explanation.add_css_class("muted");
    panel.append(&explanation);

    let display_name = Entry::builder()
        .placeholder_text("Your display name")
        .hexpand(true)
        .build();
    panel.append(&display_name);

    let invite = TextView::new();
    invite.set_wrap_mode(WrapMode::WordChar);
    invite.set_monospace(true);
    invite.set_top_margin(10);
    invite.set_bottom_margin(10);
    invite.set_left_margin(10);
    invite.set_right_margin(10);
    let invite_scroller = ScrolledWindow::builder()
        .min_content_height(180)
        .hexpand(true)
        .child(&invite)
        .build();
    panel.append(&invite_scroller);

    let submit = Button::with_label("Request host approval");
    submit.add_css_class("suggested-action");
    submit.set_halign(Align::End);
    panel.append(&submit);
    let notice = Label::new(initial_notice.as_deref());
    notice.set_wrap(true);
    notice.set_xalign(0.0);
    notice.add_css_class("muted");
    panel.append(&notice);

    let Some(client) = client else {
        display_name.set_sensitive(false);
        invite.set_sensitive(false);
        submit.set_sensitive(false);
        notice.set_label("The signed Link core is unavailable. Reinstall Kaname Link.");
        container.append(&panel);
        return;
    };

    let destination = container.clone();
    submit.connect_clicked(move |_| {
        let buffer = invite.buffer();
        let invite_text = buffer
            .text(&buffer.start_iter(), &buffer.end_iter(), false)
            .to_string();
        match client.enroll(&invite_text, display_name.text().as_str()) {
            Ok(outcome) => {
                let enrollment_notice = format!(
                    "Enrollment requested. Compare this verification code with the host before approval: {}",
                    outcome.verification_code
                );
                render_content(
                    &destination,
                    outcome.snapshot,
                    Some(Rc::clone(&client)),
                    false,
                    Some(enrollment_notice),
                );
            }
            Err(error) => {
                notice.set_label(&format!(
                    "Enrollment was not accepted ({}). Check the invitation and try again.",
                    error.code()
                ));
            }
        }
    });
    container.append(&panel);
}

fn render_workspace(
    container: &GtkBox,
    snapshot: LinkSnapshot,
    client: Option<Rc<CoreClient>>,
    synthetic: bool,
    notice: Option<String>,
) {
    let has_notice = notice.is_some();
    if let Some(notice) = notice {
        let banner = Label::new(Some(&notice));
        banner.add_css_class("notice-banner");
        banner.set_wrap(true);
        banner.set_xalign(0.0);
        banner.set_margin_start(12);
        banner.set_margin_end(12);
        banner.set_margin_top(8);
        banner.set_margin_bottom(8);
        container.append(&banner);
    }
    if !has_notice
        && matches!(
            snapshot.connection_status(),
            LinkConnectionStatus::Connecting
        )
        && let Some(code) = snapshot.verification_code_for_display()
    {
        let banner = Label::new(Some(&format!(
            "Compare this verification code with the host before approval: {code}"
        )));
        banner.add_css_class("notice-banner");
        banner.set_wrap(true);
        banner.set_xalign(0.0);
        banner.set_margin_start(12);
        banner.set_margin_end(12);
        banner.set_margin_top(8);
        banner.set_margin_bottom(8);
        container.append(&banner);
    }

    let split = Paned::new(Orientation::Horizontal);
    split.set_position(260);
    split.set_wide_handle(true);
    let sidebar = build_sidebar(&snapshot, container, client.clone(), synthetic);
    split.set_start_child(Some(&sidebar));

    let secondary = Paned::new(Orientation::Horizontal);
    secondary.set_position(330);
    let discussions = ListBox::new();
    discussions.set_selection_mode(SelectionMode::Single);
    let detail = GtkBox::new(Orientation::Vertical, 0);
    secondary.set_start_child(Some(&discussions));
    secondary.set_end_child(Some(&detail));
    split.set_end_child(Some(&secondary));
    split.set_vexpand(true);
    container.append(&split);

    let state = Rc::new(RefCell::new(snapshot));
    populate_discussions(&discussions, state.borrow().spaces.first());
    let initial_space_id = state.borrow().spaces.first().map(|space| space.id.clone());
    let initial_discussion = state
        .borrow()
        .spaces
        .first()
        .and_then(|space| space.discussions.first())
        .cloned();
    render_detail(
        &detail,
        initial_discussion.as_ref(),
        DetailContext {
            space_id: initial_space_id.as_deref(),
            connection: state.borrow().connection_status(),
            destination: container,
            client: client.clone(),
            synthetic,
        },
    );

    {
        let state = Rc::clone(&state);
        let detail = detail.clone();
        let destination = container.clone();
        let client = client.clone();
        discussions.connect_row_selected(move |_, row| {
            let Some(row) = row else { return };
            let index = row.index() as usize;
            let borrowed = state.borrow();
            let space_id = borrowed.spaces.first().map(|space| space.id.clone());
            let selected = borrowed
                .spaces
                .first()
                .and_then(|space| space.discussions.get(index))
                .cloned();
            let connection = borrowed.connection_status();
            drop(borrowed);
            render_detail(
                &detail,
                selected.as_ref(),
                DetailContext {
                    space_id: space_id.as_deref(),
                    connection,
                    destination: &destination,
                    client: client.clone(),
                    synthetic,
                },
            );
        });
    }
    if let Some(row) = discussions.row_at_index(0) {
        discussions.select_row(Some(&row));
    }
}

fn build_sidebar(
    snapshot: &LinkSnapshot,
    destination: &GtkBox,
    client: Option<Rc<CoreClient>>,
    synthetic: bool,
) -> GtkBox {
    let sidebar = GtkBox::new(Orientation::Vertical, 16);
    sidebar.add_css_class("sidebar");
    sidebar.set_size_request(260, -1);
    sidebar.set_margin_start(18);
    sidebar.set_margin_end(18);
    sidebar.set_margin_top(18);
    sidebar.set_margin_bottom(18);

    let title = Label::new(Some("Kaname Link"));
    title.add_css_class("title");
    title.set_halign(Align::Start);
    sidebar.append(&title);
    let subtitle = Label::new(Some("External collaboration"));
    subtitle.add_css_class("muted");
    subtitle.set_halign(Align::Start);
    sidebar.append(&subtitle);

    let connection = status_badge(snapshot.connection_status().presentation());
    connection.set_halign(Align::Start);
    sidebar.append(&connection);
    if !synthetic && let Some(client) = client {
        let refresh = Button::with_label("Refresh");
        let destination = destination.clone();
        let fallback_snapshot = snapshot.clone();
        refresh.connect_clicked(move |_| match client.snapshot() {
            Ok(snapshot) => render_content(
                &destination,
                snapshot,
                Some(Rc::clone(&client)),
                false,
                None,
            ),
            Err(error) => {
                let mut snapshot = fallback_snapshot.clone();
                snapshot.connection = "hostOffline".to_owned();
                snapshot.diagnostic_code = Some(error.code().to_owned());
                render_content(
                    &destination,
                    snapshot,
                    Some(Rc::clone(&client)),
                    false,
                    Some(format!(
                        "The host could not be refreshed ({}).",
                        error.code()
                    )),
                );
            }
        });
        sidebar.append(&refresh);
    }

    let spaces_label = Label::new(Some("LINK SPACES"));
    spaces_label.add_css_class("section-label");
    spaces_label.set_halign(Align::Start);
    sidebar.append(&spaces_label);
    for space in &snapshot.spaces {
        let row = GtkBox::new(Orientation::Vertical, 4);
        row.add_css_class("space-card");

        let name = Label::new(Some(&space.name));
        name.set_wrap(true);
        name.set_xalign(0.0);
        row.append(&name);

        let host = GtkBox::new(Orientation::Horizontal, 4);
        let host_name = Label::new(Some(&format!("{} ·", space.host_name)));
        host_name.add_css_class("muted");
        host.append(&host_name);
        let verification =
            status_badge(LinkHostVerificationState::from_verified(space.verified).presentation());
        host.append(&verification);
        row.append(&host);
        sidebar.append(&row);
    }
    if let Some(code) = &snapshot.diagnostic_code {
        let diagnostic = Label::new(Some(&format!("Status code: {code}")));
        diagnostic.set_wrap(true);
        diagnostic.set_xalign(0.0);
        diagnostic.add_css_class("muted");
        sidebar.append(&diagnostic);
    }
    let boundary = Label::new(Some(
        "This app cannot control Kaname, tools, models, files, or the host computer.",
    ));
    boundary.set_wrap(true);
    boundary.set_xalign(0.0);
    boundary.add_css_class("muted");
    sidebar.append(&boundary);
    sidebar
}

fn populate_discussions(list: &ListBox, space: Option<&LinkSpace>) {
    let Some(space) = space else { return };
    for discussion in &space.discussions {
        let row = ListBoxRow::new();
        let content = GtkBox::new(Orientation::Vertical, 5);
        content.set_margin_start(16);
        content.set_margin_end(16);
        content.set_margin_top(14);
        content.set_margin_bottom(14);
        let title = Label::new(Some(&discussion.title));
        title.set_halign(Align::Start);
        title.add_css_class("discussion-title");
        content.append(&title);
        let status = status_badge(discussion.status_kind().presentation());
        status.set_halign(Align::Start);
        content.append(&status);
        let action = Label::new(Some(&discussion.action_label));
        action.set_halign(Align::Start);
        action.add_css_class("muted");
        content.append(&action);
        row.set_child(Some(&content));
        list.append(&row);
    }
}

struct DetailContext<'a> {
    space_id: Option<&'a str>,
    connection: LinkConnectionStatus,
    destination: &'a GtkBox,
    client: Option<Rc<CoreClient>>,
    synthetic: bool,
}

fn render_detail(
    container: &GtkBox,
    discussion: Option<&LinkDiscussion>,
    context: DetailContext<'_>,
) {
    clear(container);
    let Some(discussion) = discussion else {
        let message = if matches!(&context.connection, LinkConnectionStatus::Connecting) {
            "Waiting for the host to approve this device. Use Refresh after approval."
        } else {
            "Select a Link discussion to see deliberately shared messages."
        };
        let empty = Label::new(Some(message));
        empty.add_css_class("muted");
        empty.set_wrap(true);
        empty.set_margin_start(32);
        empty.set_margin_end(32);
        empty.set_margin_top(48);
        container.append(&empty);
        return;
    };
    let heading = GtkBox::new(Orientation::Vertical, 4);
    heading.set_margin_start(22);
    heading.set_margin_end(22);
    heading.set_margin_top(18);
    heading.set_margin_bottom(18);
    let title = Label::new(Some(&discussion.title));
    title.add_css_class("title");
    title.set_halign(Align::Start);
    heading.append(&title);
    let status = status_badge(discussion.status_kind().presentation());
    status.set_halign(Align::Start);
    heading.append(&status);
    container.append(&heading);

    let messages = GtkBox::new(Orientation::Vertical, 12);
    messages.set_margin_start(22);
    messages.set_margin_end(22);
    messages.set_margin_top(18);
    messages.set_margin_bottom(18);
    for message in &discussion.messages {
        let participant = message.participant_role();
        let card = GtkBox::new(Orientation::Vertical, 7);
        card.add_css_class(if participant.is_local_principal() {
            "own-message"
        } else {
            "host-message"
        });
        card.set_margin_start(if participant.is_local_principal() {
            80
        } else {
            0
        });
        card.set_margin_end(if participant.is_local_principal() {
            0
        } else {
            80
        });
        let author = Label::new(Some(&message.author_name));
        author.set_halign(Align::Start);
        author.add_css_class("message-author");
        let participant_accessibility = participant.presentation().accessibility_label;
        author.update_property(&[gtk::accessible::Property::Label(&participant_accessibility)]);
        card.append(&author);
        let body = Label::new(Some(&message.body));
        body.set_wrap(true);
        body.set_selectable(true);
        body.set_xalign(0.0);
        card.append(&body);
        let receipt = status_badge(message.receipt_status().presentation());
        receipt.set_halign(Align::Start);
        card.append(&receipt);
        messages.append(&card);
    }
    let scroller = ScrolledWindow::builder()
        .hexpand(true)
        .vexpand(true)
        .child(&messages)
        .build();
    container.append(&scroller);

    let composer = GtkBox::new(Orientation::Vertical, 8);
    composer.set_margin_start(18);
    composer.set_margin_end(18);
    composer.set_margin_top(12);
    composer.set_margin_bottom(18);
    let controls = GtkBox::new(Orientation::Horizontal, 10);
    let entry = Entry::builder()
        .placeholder_text("Message the host")
        .hexpand(true)
        .build();
    let send = Button::with_label("Send");
    send.add_css_class("suggested-action");
    let enabled = !context.synthetic
        && context.connection.capabilities().can_queue_message
        && context.client.is_some()
        && context.space_id.is_some();
    entry.set_sensitive(enabled);
    send.set_sensitive(enabled);
    controls.append(&entry);
    controls.append(&send);
    composer.append(&controls);
    let send_notice = Label::new(None);
    send_notice.set_wrap(true);
    send_notice.set_xalign(0.0);
    send_notice.add_css_class("muted");
    composer.append(&send_notice);
    container.append(&composer);

    if enabled {
        let client = context
            .client
            .expect("enabled composer requires a core client");
        let space_id = context
            .space_id
            .expect("enabled composer requires a space")
            .to_owned();
        let discussion_id = discussion.id.clone();
        let destination = context.destination.clone();
        let entry_for_send = entry.clone();
        let send_notice_for_send = send_notice.clone();
        let client_for_send = Rc::clone(&client);
        send.connect_clicked(move |_| {
            match client_for_send.send_message(
                &space_id,
                &discussion_id,
                entry_for_send.text().as_str(),
            ) {
                Ok(snapshot) => {
                    entry_for_send.set_text("");
                    render_content(
                        &destination,
                        snapshot,
                        Some(Rc::clone(&client_for_send)),
                        false,
                        Some("Message saved locally and delivery was attempted.".to_owned()),
                    );
                }
                Err(error) => send_notice_for_send.set_label(&format!(
                    "The message was not submitted ({}).",
                    error.code()
                )),
            }
        });
        let send_for_activate = send.clone();
        entry.connect_activate(move |_| send_for_activate.emit_clicked());
    }
}

fn clear(container: &GtkBox) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }
}

fn core_unavailable_snapshot() -> LinkSnapshot {
    LinkSnapshot {
        connection: "hostOffline".to_owned(),
        last_sync_unix_millis: None,
        spaces: Vec::new(),
        diagnostic_code: Some("LINK-CORE-UNAVAILABLE".to_owned()),
        verification_code: None,
    }
}

fn status_badge(presentation: LinkStatusPresentation) -> GtkBox {
    let badge = GtkBox::builder()
        .orientation(Orientation::Horizontal)
        .spacing(4)
        .accessible_role(AccessibleRole::Group)
        .build();
    badge.add_css_class("status-badge");
    badge.add_css_class(presentation.tone.css_class());
    badge.update_property(&[gtk::accessible::Property::Label(
        &presentation.accessibility_label,
    )]);

    let icon = Image::builder()
        .accessible_role(AccessibleRole::Presentation)
        .build();
    icon.add_css_class("status-icon");
    icon.add_css_class(presentation.tone.icon_css_class());
    badge.append(&icon);

    let label = Label::new(Some(presentation.label));
    badge.append(&label);
    badge
}

fn install_css() {
    let css = CssProvider::new();
    css.load_from_data(concat!(
        include_str!("kaname-theme.css"),
        "\n",
        include_str!("kaname-components.css")
    ));
    if let Some(display) = Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}

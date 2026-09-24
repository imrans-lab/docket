//! Contains helpers for:
//!   locking/unlocking
//!   exec_prompt
//!   formatting secrets

use crate::error::Error;
use crate::proxy::SecretStruct;
use crate::proxy::prompt::{PromptProxy, PromptProxyBlocking};
use crate::proxy::service::{ServiceProxy, ServiceProxyBlocking};
use crate::session::Session;
use crate::session::encrypt;
use crate::ss::SS_DBUS_NAME;

use zbus::{
    proxy::CacheProperties,
    zvariant::{self, ObjectPath},
};

// Helper enum for locking
pub(crate) enum LockAction {
    Lock,
    Unlock,
}

pub(crate) async fn lock_or_unlock(
    conn: zbus::Connection,
    service_proxy: &ServiceProxy<'_>,
    object_path: &ObjectPath<'_>,
    lock_action: LockAction,
) -> Result<(), Error> {
    let objects = vec![object_path];

    let lock_action_res = match lock_action {
        LockAction::Lock => service_proxy.lock(objects).await?,
        LockAction::Unlock => service_proxy.unlock(objects).await?,
    };

    if lock_action_res.object_paths.is_empty() {
        exec_prompt(conn, &lock_action_res.prompt).await?;
    }
    Ok(())
}

pub(crate) fn lock_or_unlock_blocking(
    conn: zbus::blocking::Connection,
    service_proxy: &ServiceProxyBlocking,
    object_path: &ObjectPath,
    lock_action: LockAction,
) -> Result<(), Error> {
    let objects = vec![object_path];

    let lock_action_res = match lock_action {
        LockAction::Lock => service_proxy.lock(objects)?,
        LockAction::Unlock => service_proxy.unlock(objects)?,
    };

    if lock_action_res.object_paths.is_empty() {
        exec_prompt_blocking(conn, &lock_action_res.prompt)?;
    }
    Ok(())
}

pub(crate) fn format_secret(
    session: &Session,
    secret: &[u8],
    content_type: &str,
) -> Result<SecretStruct, Error> {
    let content_type = content_type.to_owned();

    if let Some(session_key) = session.get_aes_key() {
        let mut aes_iv = [0; 16];
        getrandom::fill(&mut aes_iv).expect("platform RNG failed");

        let encrypted_secret = encrypt(secret, session_key, &aes_iv);

        // Construct secret struct
        let parameters = aes_iv.to_vec();
        let value = encrypted_secret;

        Ok(SecretStruct {
            session: session.object_path.clone(),
            parameters,
            value,
            content_type,
        })
    } else {
        // just Plain for now
        let parameters = Vec::new();
        let value = secret.to_vec();

        Ok(SecretStruct {
            session: session.object_path.clone(),
            parameters,
            value,
            content_type,
        })
    }
}

// Docket patch: a prompt is never shown and never waited for. The service
// asked for the user's confirmation, which Docket does not ask for, so the
// prompt is dismissed (best effort, within the caller's deadline) and the
// request is refused with Error::Prompt.
pub(crate) async fn exec_prompt(
    conn: zbus::Connection,
    prompt: &ObjectPath<'_>,
) -> Result<zvariant::OwnedValue, Error> {
    if let Ok(builder) = PromptProxy::builder(&conn).destination(SS_DBUS_NAME) {
        if let Ok(builder) = builder.path(prompt) {
            if let Ok(prompt_proxy) = builder.cache_properties(CacheProperties::No).build().await {
                let _ = prompt_proxy.dismiss().await;
            }
        }
    }
    Err(Error::Prompt)
}

// Docket patch: as exec_prompt.
pub(crate) fn exec_prompt_blocking(
    conn: zbus::blocking::Connection,
    prompt: &ObjectPath,
) -> Result<zvariant::OwnedValue, Error> {
    if let Ok(builder) = PromptProxyBlocking::builder(&conn).destination(SS_DBUS_NAME) {
        if let Ok(builder) = builder.path(prompt) {
            if let Ok(prompt_proxy) = builder.cache_properties(CacheProperties::No).build() {
                let _ = prompt_proxy.dismiss();
            }
        }
    }
    Err(Error::Prompt)
}

pub(crate) fn handle_conn_error(e: zbus::Error) -> Error {
    match e {
        zbus::Error::InterfaceNotFound | zbus::Error::Address(_) => Error::Unavailable,
        zbus::Error::InputOutput(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Error::Unavailable
        }
        e => e.into(),
    }
}

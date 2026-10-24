// Clean-room implementation from the WallpaperMachine spec r1c-core-media.md; written without access to the original source.
use std::path::{Path, PathBuf};

use super::{ProjectManifest, WallpaperProjectType, validate_relative_normal_path};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SceneSourcePaths {
    pub pkg_path: PathBuf,
    pub pkg_entry: String,
    pub pkg_dir: PathBuf,
    pub scene_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SceneSourceResolution {
    Scene {
        manifest: ProjectManifest,
        scene_source: SceneSourcePaths,
    },
    NotSceneProject {
        manifest: ProjectManifest,
    },
}

impl SceneSourceResolution {
    /// # Errors
    ///
    /// Returns `InvalidInput` for an empty path, an unreadable manifest or an unsafe entry.
    pub fn load<T: AsRef<Path>>(project_path: T) -> Result<Self, crate::EngineError> {
        let path = project_path.as_ref();
        if path.as_os_str().is_empty() {
            return Err(crate::EngineError::InvalidInput(
                "scene source path must not be empty".to_owned(),
            ));
        }

        let manifest = if path.file_name().is_some_and(|name| name == "project.json") {
            let manifest = ProjectManifest::load(path)?;
            if manifest.project_type() != WallpaperProjectType::Scene {
                return Ok(Self::NotSceneProject { manifest });
            }
            manifest
        } else {
            let Some(file_name) = path.file_name() else {
                return Err(crate::EngineError::InvalidInput(
                    "scene source must include a file name".to_owned(),
                ));
            };
            let mut manifest = ProjectManifest::default();
            manifest.assign_project_type(WallpaperProjectType::Scene);
            manifest.assign_file(file_name.to_string_lossy().into_owned());
            let parent_name = path
                .parent()
                .and_then(Path::file_name)
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default();
            manifest.assign_workshop_id(parent_name);
            manifest
        };

        let entry = if manifest.file().is_empty() {
            "scene.json"
        } else {
            manifest.file()
        };
        validate_relative_normal_path(Path::new(entry), "project scene entry")?;

        let pkg_dir = path.parent().map(Path::to_path_buf).unwrap_or_default();
        let scene_id = pkg_dir
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let scene_source = SceneSourcePaths {
            pkg_path: pkg_dir.join(entry).with_extension("pkg"),
            pkg_entry: Path::new(entry)
                .with_extension("json")
                .to_string_lossy()
                .replace('\\', "/"),
            pkg_dir,
            scene_id,
        };
        Ok(Self::Scene {
            manifest,
            scene_source,
        })
    }

    #[must_use]
    pub fn scene_source(&self) -> Option<&SceneSourcePaths> {
        match self {
            Self::Scene { scene_source, .. } => Some(scene_source),
            Self::NotSceneProject { .. } => None,
        }
    }
}

impl ProjectManifest {
    pub fn set_project_type(&mut self, project_type: WallpaperProjectType) {
        self.assign_project_type(project_type);
    }

    pub fn set_file(&mut self, file: String) {
        self.assign_file(file);
    }

    pub fn set_workshop_id(&mut self, workshop_id: String) {
        self.assign_workshop_id(workshop_id);
    }
}
